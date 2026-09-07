import Foundation

/// Applies filesystem changes (from FSEvents) to a scanned tree.
///
/// One exact rule: for every changed path, re-walk the affected DIRECTORY —
/// the changed path itself if it is a directory present in the tree,
/// otherwise the deepest tree node containing it (for a changed file, that is
/// usually its parent). Directory re-walks measure the new state for real
/// (never estimated), so creates, deletes, renames, and size changes all
/// reconcile identically — no per-file edge cases.
///
/// Delta propagation mirrors `StorageNode.removeDescendants`: sizes/counts
/// adjust up the ancestor chain so every aggregate stays consistent.
///
/// @MainActor: tree mutations must be confined to the main actor (SwiftUI
/// renders the same class instances); the re-walks inside still run on the
/// dedicated enumeration pool via their own awaits.
@MainActor
public enum TreeReconciler {
    public static func reconcile(changedPaths: [String], root: StorageNode, options: ScanOptions) async -> Bool {
        guard !changedPaths.isEmpty else { return false }

        // Path → node index over the whole tree (one O(n) pass).
        var byPath: [String: StorageNode] = [root.path: root]
        func index(_ node: StorageNode) {
            for child in node.children {
                byPath[child.path] = child
                index(child)
            }
        }
        index(root)

        // Map each changed path to the deepest node that CONTAINS it: the
        // node at the path when it exists (a changed directory), else the
        // nearest ancestor present (a changed file → its parent, or higher
        // when the parent is new to the tree).
        var affected: Set<String> = []
        for rawPath in changedPaths {
            let path = (rawPath as NSString).standardizingPath
            guard PathKit.isDescendant(path: path, of: root.path) else { continue }
            if let node = byPath[path] {
                // A directory already in the tree: re-walk it.
                affected.insert(node.path)
                continue
            }
            // Walk up to the deepest ancestor that exists in the tree.
            var ancestor = (path as NSString).deletingLastPathComponent
            while ancestor != "/" {
                if byPath[ancestor] != nil {
                    affected.insert(ancestor)
                    break
                }
                ancestor = (ancestor as NSString).deletingLastPathComponent
            }
        }
        guard !affected.isEmpty else { return false }

        var anyChanged = false
        for affectedPath in affected {
            if affectedPath == root.path {
                // The scan root itself changed — re-walk the whole root
                // subtree's children (equivalent to a fresh scan of the same
                // roots, still cheaper than re-materializing everything).
                let delta = await rewalk(root, options: options)
                anyChanged = anyChanged || delta
                continue
            }
            guard let node = byPath[affectedPath], let parent = parent(of: node, root: root) else { continue }
            let replacement = await ScanEngine.walk(node.url, depth: 0, options: options,
                                                    tracker: ScanProgressTracker(),
                                                    continuation: nil, startedAt: Date())
            // The walker returns a fresh node for the same URL.
            let deltaBytes = replacement.size - node.size
            let deltaFiles = replacement.fileCount - node.fileCount
            let deltaDirs = replacement.directoryCount - node.directoryCount
            if deltaBytes == 0, deltaFiles == 0, deltaDirs == 0,
               replacement.children.map(\.path) == node.children.map(\.path) {
                continue  // genuinely unchanged
            }
            anyChanged = true
            if let index = parent.children.firstIndex(where: { $0.path == node.path }) {
                parent.children[index] = replacement
            } else {
                parent.children.append(replacement)
            }
            parent.children.sort { $0.size > $1.size }
            // Propagate the delta above the parent.
            adjustAncestors(of: parent, root: root,
                            bytes: deltaBytes, files: deltaFiles, directories: deltaDirs)
            // Keep the index fresh for subsequent affected paths.
            byPath[replacement.path] = replacement
        }
        return anyChanged
    }

    /// Re-walks the root's own subtree in place (root-level changes).
    private static func rewalk(_ root: StorageNode, options: ScanOptions) async -> Bool {
        let replacement = await ScanEngine.walk(root.url, depth: 0, options: options,
                                                tracker: ScanProgressTracker(),
                                                continuation: nil, startedAt: Date())
        let changed = replacement.size != root.size
            || replacement.fileCount != root.fileCount
            || replacement.directoryCount != root.directoryCount
        root.children = replacement.children
        root.size = replacement.size
        root.fileCount = replacement.fileCount
        root.directoryCount = replacement.directoryCount
        root.smallFileCount = replacement.smallFileCount
        root.smallFileBytes = replacement.smallFileBytes
        root.symlinkCount = replacement.symlinkCount
        return changed
    }

    private static func parent(of node: StorageNode, root: StorageNode) -> StorageNode? {
        if root.children.contains(where: { $0.path == node.path }) { return root }
        var found: StorageNode?
        func visit(_ current: StorageNode) {
            if found != nil { return }
            for child in current.children {
                if child.path == node.path { found = current; return }
                visit(child)
            }
        }
        visit(root)
        return found
    }

    private static func adjustAncestors(of node: StorageNode, root: StorageNode,
                                        bytes: Int64, files: Int, directories: Int) {
        guard bytes != 0 || files != 0 || directories != 0 else { return }
        // Build the path chain from root down to the node's parent.
        func adjust(_ current: StorageNode) -> Bool {
            if current === node {
                current.size = max(0, current.size + bytes)
                current.fileCount = max(0, current.fileCount + files)
                current.directoryCount = max(0, current.directoryCount + directories)
                return true
            }
            for child in current.children where adjust(child) {
                current.size = max(0, current.size + bytes)
                current.fileCount = max(0, current.fileCount + files)
                current.directoryCount = max(0, current.directoryCount + directories)
                return true
            }
            return false
        }
        _ = adjust(root)
    }
}
