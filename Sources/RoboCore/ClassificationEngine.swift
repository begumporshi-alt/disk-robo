import Foundation

/// Deterministic path/extension → category classification.
/// Rules are ordered: system/protected first, then specific user domains,
/// then file-extension heuristics. Unknown paths default to `.other`.
public struct ClassificationEngine: Sendable {
    public let home: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    public func classifyTree(_ root: StorageNode) {
        func visit(_ n: StorageNode) {
            n.category = classify(path: n.url.path, kind: n.kind)
            for c in n.children { visit(c) }
        }
        visit(root)
    }

    public func classify(path: String, kind: NodeKind) -> StorageCategory {
        let p = PathKit.normalize(path)
        let h = PathKit.normalize(home.path)
        let ext = (p as NSString).pathExtension

        // --- System & protected locations ---
        if p == "/"
            || p.hasPrefix("/system") || p.hasPrefix("/usr") || p.hasPrefix("/bin") || p.hasPrefix("/sbin")
            || p.hasPrefix("/private/var/db") || p.hasPrefix("/private/var/vm") || p.hasPrefix("/private/var/protected")
            || p.hasPrefix("/private/etc") || p.hasPrefix("/etc")
            || p.hasPrefix("/library/apple") || p.hasPrefix("/library/system") {
            return .system
        }
        if p.hasPrefix(h + "/library/mail") || p.hasPrefix(h + "/library/messages")
            || p.hasPrefix(h + "/library/keychains") || p.hasPrefix(h + "/library/safari")
            || p.hasPrefix(h + "/library/mobile documents") || p.hasPrefix(h + "/library/cloudstorage")
            || p.hasPrefix(h + "/library/accounts") || p.hasPrefix(h + "/library/identityservices")
            || p.hasPrefix(h + "/library/application support/mobilesync")
            || p.hasPrefix(h + "/library/group containers") {
            return .system
        }

        // --- Trash ---
        if p == h + "/.trash" || p.hasPrefix(h + "/.trash/") || p.contains("/.trashes/") {
            return .trash
        }

        // --- Applications ---
        if p.hasPrefix("/applications") || p.hasPrefix(h + "/applications")
            || (kind == .package && p.hasSuffix(".app")) {
            return .applications
        }

        // --- Developer domains ---
        if p.hasPrefix(h + "/library/developer") || p.hasPrefix("/library/developer")
            || p.contains("/deriveddata") || p.contains("/node_modules") || p.contains("/.build/")
            || p.hasPrefix(h + "/.npm") || p.hasPrefix(h + "/.cache") || p.hasPrefix(h + "/.cargo")
            || p.hasPrefix(h + "/.rustup") || p.hasPrefix(h + "/.gradle") || p.hasPrefix(h + "/.m2")
            || p.hasPrefix(h + "/.cocoapods")
            || (kind == .directory && (p.hasSuffix(".xcodeproj") || p.hasSuffix(".xcworkspace") || p.hasSuffix(".git"))) {
            return .developer
        }

        // --- Caches (including container-internal caches) & browser data ---
        if p.contains("/library/caches") {
            if Self.browserMarkers.contains(where: { p.contains($0) }) { return .browser }
            return .caches
        }

        // --- Logs ---
        if p.hasPrefix(h + "/library/logs") || p.hasPrefix("/library/logs") {
            return .logs
        }

        // --- Other app-related library domains ---
        if p.hasPrefix(h + "/library/containers") {
            return p.contains("/com.apple.") ? .system : .applications
        }
        if p.hasPrefix(h + "/library/application support")
            || p.hasPrefix(h + "/library/preferences")
            || p.hasPrefix(h + "/library/saved application state")
            || p.hasPrefix(h + "/library/webkit")
            || p.hasPrefix(h + "/library/httpstorages") {
            return .applications
        }

        // --- Downloads (file-level overrides for cleanup relevance) ---
        if p.hasPrefix(h + "/downloads") {
            if kind == .file {
                if Self.installerExtensions.contains(ext) { return .installers }
                if Self.archiveExtensions.contains(ext) { return .archives }
            }
            return .downloads
        }

        // --- Media homes ---
        if p.hasPrefix(h + "/movies") || p.hasPrefix(h + "/music") || p.hasPrefix(h + "/pictures")
            || p.hasPrefix(h + "/photos library") {
            return .media
        }

        // --- File extension heuristics ---
        if kind != .directory {
            if Self.installerExtensions.contains(ext) { return .installers }
            if Self.archiveExtensions.contains(ext) { return .archives }
            if Self.mediaExtensions.contains(ext) { return .media }
            if Self.documentExtensions.contains(ext) { return .documents }
        }

        return .other
    }

    static let installerExtensions: Set<String> = ["dmg", "pkg", "mpkg", "ipsw", "ipa"]
    static let archiveExtensions: Set<String> = ["zip", "rar", "7z", "tar", "gz", "bz2", "xz", "iso", "cab", "tgz"]
    static let mediaExtensions: Set<String> = [
        "mp4", "mov", "mkv", "avi", "m4v", "webm", "mp3", "wav", "aac", "flac", "aiff", "alac", "m4a",
        "heic", "jpg", "jpeg", "png", "gif", "tiff", "webp", "cr2", "crw", "nef", "arw", "raf", "dng", "psd", "raw"
    ]
    static let documentExtensions: Set<String> = [
        "pdf", "doc", "docx", "pages", "rtf", "txt", "md", "key", "ppt", "pptx", "numbers", "xls", "xlsx", "csv", "epub"
    ]
    static let browserMarkers: Set<String> = [
        "chrome", "safari", "firefox", "chromium", "brave", "edge", "arc", "vivaldi", "opera"
    ]
}
