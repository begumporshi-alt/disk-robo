import Foundation

/// Fingerprint of a filesystem item, captured at discovery time and re-verified
/// immediately before any destructive operation (TOCTOU protection).
public struct ItemFingerprint: Codable, Sendable, Equatable, Hashable {
    public let path: String
    public let size: Int64
    public let mtime: Double

    public init(path: String, size: Int64, mtime: Double) {
        self.path = path
        self.size = size
        self.mtime = mtime
    }

    /// Captures size + mtime via a bare `lstat` — deliberately NOT
    /// `FileManager.attributesOfItem`, whose extended-attributes read
    /// (`getxattr`) stalls forever on TCC-protected paths. The stat itself
    /// runs on the watched pool (invariant 9): a stalled path times out and
    /// yields nil, which safely skips the TOCTOU re-check (all other safety
    /// layers still apply).
    public static func capture(path: String) async -> ItemFingerprint? {
        await EnumerationWorkers.shared.runWatched(timeout: 2) {
            var st = stat()
            guard lstat(path, &st) == 0 else { return nil }
            let mtime = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1_000_000_000
            return ItemFingerprint(path: path, size: Int64(st.st_size), mtime: mtime)
        } ?? nil
    }
}

/// Single-use, short-lived approval issued by an explicit user confirmation.
/// Required for every engine-initiated destructive operation.
public struct ApprovalToken: Sendable, Equatable {
    public let id: UUID
    public let paths: Set<String>
    public let issuedAt: Date
    public let ttl: TimeInterval

    public static func issue(paths: [String], ttl: TimeInterval = 300) -> ApprovalToken {
        ApprovalToken(id: UUID(), paths: Set(paths.map { PathKit.normalize($0) }), issuedAt: Date(), ttl: ttl)
    }

    public func covers(_ path: String, at date: Date = Date()) -> Bool {
        paths.contains(PathKit.normalize(path)) && date.timeIntervalSince(issuedAt) <= ttl
    }
}

public enum SafetyDecision: Equatable, Sendable {
    case allowed
    case vetoed(reason: String)
}

/// The Safety Guardian. Has veto authority over every destructive operation
/// proposed by any component. All checks are deterministic.
public struct SafetyEngine: Sendable {
    public let home: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    /// Locations that are never deletable as a whole, but whose *contents* may
    /// be (the user's home itself, the filesystem root, and the top-level
    /// Library data roots — SV-1 defense-in-depth so no code path can ever
    /// offer e.g. ~/Library/Application Support itself for deletion).
    public var protectedExactPaths: [String] {
        let h = PathKit.normalize(home.path)
        return [
            "/", h,
            h + "/library/application support", h + "/library/caches", h + "/library/containers",
            h + "/library/logs", h + "/library/webkit", h + "/library/httpstorages",
            h + "/library/saved application state",
            "/library/caches", "/library/logs",
        ]
    }

    /// Trees inside which nothing is ever deletable through any flow (hard veto).
    public var protectedPaths: [String] {
        let h = PathKit.normalize(home.path)
        return [
            "/system", "/usr", "/bin", "/sbin", "/etc", "/private/etc",
            "/private/var/db", "/private/var/vm", "/private/var/protected",
            "/library/apple", "/library/system", "/library/preferences",
            h + "/library/mail", h + "/library/messages", h + "/library/keychains",
            h + "/library/safari", h + "/library/mobile documents", h + "/library/cloudstorage",
            h + "/library/group containers", h + "/library/accounts", h + "/library/identityservices",
            h + "/library/application support/mobilesync", h + "/library/metadata",
            h + "/library/assistantservices", h + "/library/continuity", h + "/library/autosave information",
        ]
    }

    /// True when the path itself (or its symlink-resolved spelling) is protected.
    /// Exact paths match only themselves; trees match everything inside them.
    public func isProtected(_ normalized: String, resolved: String) -> Bool {
        if protectedExactPaths.contains(normalized) || protectedExactPaths.contains(resolved) {
            return true
        }
        return protectedPaths.contains { PathKit.isDescendant(path: normalized, of: $0) }
            || protectedPaths.contains { PathKit.isDescendant(path: resolved, of: $0) }
    }

    /// The only roots inside which the *engine* may propose deletions.
    /// Anything outside requires explicit per-item user selection in the UI
    /// (which still passes the protected-path veto below).
    public var engineAllowlist: [String] {
        let h = PathKit.normalize(home.path)
        return [
            h + "/.trash",
            h + "/library/caches", "/library/caches",
            h + "/library/logs", "/library/logs",
            h + "/library/developer/xcode/deriveddata",
            h + "/library/developer/xcode/ios devicesupport",
            h + "/library/developer/coresimulator/caches",
            h + "/.npm", h + "/.cache",
            h + "/downloads",
            h + "/library/developer/xcode/archives",
        ]
    }

    /// Full validation for a prospective trash operation.
    /// Order: existence → TOCTOU fingerprint → protected paths (original AND
    /// symlink-resolved spelling) → depth floor → engine allowlist.
    /// The existence/size/mtime read uses a bare lstat — attributesOfItem's
    /// xattr read stalls on TCC-protected paths.
    public func validateTrash(path: String, userInitiated: Bool, expectedFingerprint: ItemFingerprint?) -> SafetyDecision {
        var st = stat()
        guard lstat(path, &st) == 0 else {
            return .vetoed(reason: "Item no longer exists on disk.")
        }
        let actualSize = Int64(st.st_size)
        let actualMtime = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1_000_000_000

        if let fp = expectedFingerprint {
            if fp.size != actualSize || abs(fp.mtime - actualMtime) > 1.0 {
                return .vetoed(reason: "Item changed since the scan (size or modification date differs). Re-scan before cleaning.")
            }
        }

        let normalized = PathKit.normalize(path)
        let resolved = PathKit.normalize(URL(fileURLWithPath: path).resolvingSymlinksInPath().path)

        if isProtected(normalized, resolved: resolved) {
            return .vetoed(reason: "This item is in a protected macOS location. Disk Robo will not delete it.")
        }

        let depth = normalized.split(separator: "/").count
        if userInitiated {
            if depth < 3 {
                return .vetoed(reason: "Refusing to delete a top-level location.")
            }
        } else {
            if depth < 4 {
                return .vetoed(reason: "Engine-initiated deletion requires a deeper path.")
            }
            let allowed = engineAllowlist.contains { PathKit.isDescendant(path: resolved, of: $0) }
            if !allowed {
                return .vetoed(reason: "Path is outside the engine's cleanup allowlist.")
            }
        }
        return .allowed
    }

    /// Risk classification for an arbitrary path. Never infers "safe" from size.
    /// Unknown locations are orange (potentially important), never green.
    public func riskLevel(path: String) -> RiskLevel {
        let p = PathKit.normalize(path)
        let h = PathKit.normalize(home.path)

        if isProtected(p, resolved: p) {
            return .red
        }
        if p == h + "/.trash" || p.hasPrefix(h + "/.trash/")
            || p.hasPrefix(h + "/library/caches") || p.hasPrefix("/library/caches")
            || p.hasPrefix(h + "/library/logs") || p.hasPrefix("/library/logs")
            || p.contains("/deriveddata") || p.contains("/ios devicesupport")
            || p.contains("/coresimulator/caches")
            || p.hasPrefix(h + "/.npm") || p.hasPrefix(h + "/.cache") {
            return .green
        }
        if p.hasPrefix(h + "/downloads") { return .yellow }
        let ext = (p as NSString).pathExtension
        if !ext.isEmpty && (ClassificationEngine.installerExtensions.contains(ext) || ClassificationEngine.archiveExtensions.contains(ext)) {
            return .yellow
        }
        if p.hasPrefix(h + "/library/developer") { return .orange }
        if p.hasPrefix(h + "/documents") || p.hasPrefix(h + "/desktop")
            || p.hasPrefix(h + "/movies") || p.hasPrefix(h + "/music") || p.hasPrefix(h + "/pictures") {
            return .orange
        }
        return .orange
    }
}
