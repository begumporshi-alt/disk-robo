import Foundation

/// One concrete disk location belonging to an app (bundle, cache folder, …).
/// Powers the Uninstaller review flow.
public struct AppComponent: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case bundle, applicationSupport, caches, containers, groupContainers, logs, savedState, preferences, other
    }

    public let name: String
    public let path: String
    public let bytes: Int64
    public let kind: Kind

    public var id: String { path }

    public init(name: String, path: String, bytes: Int64, kind: Kind) {
        self.name = name
        self.path = path
        self.bytes = bytes
        self.kind = kind
    }

    public var kindDisplayName: String {
        switch kind {
        case .bundle: return "Application"
        case .applicationSupport: return "Application Support"
        case .caches: return "Caches"
        case .containers: return "Containers"
        case .groupContainers: return "Group Containers"
        case .logs: return "Logs"
        case .savedState: return "Saved State"
        case .preferences: return "Preferences"
        case .other: return "Other Library Data"
        }
    }
}

/// Per-application storage footprint: bundle + all discoverable library data.
/// `libraryPath` is set for "leftover" entries (app data with no installed app).
public struct AppFootprint: Identifiable, Sendable, Hashable {
    public let name: String
    public let bundleID: String?
    public let path: String
    public let libraryPath: String
    /// Concrete locations for the Uninstaller (empty for synthetic entries).
    public let components: [AppComponent]
    public let bundleBytes: Int64
    public let applicationSupportBytes: Int64
    public let cachesBytes: Int64
    public let containersBytes: Int64
    public let groupContainersBytes: Int64
    public let logsBytes: Int64
    public let savedStateBytes: Int64
    public let preferencesBytes: Int64
    public let otherLibraryBytes: Int64

    public var id: String { bundleID ?? (path.isEmpty ? libraryPath : path) }
    public var isLeftover: Bool { path.isEmpty }
    public var totalBytes: Int64 {
        bundleBytes + applicationSupportBytes + cachesBytes + containersBytes + groupContainersBytes
            + logsBytes + savedStateBytes + preferencesBytes + otherLibraryBytes
    }

    init(name: String, bundleID: String?, path: String, libraryPath: String, components: [AppComponent],
         bundleBytes: Int64, applicationSupportBytes: Int64, cachesBytes: Int64, containersBytes: Int64,
         groupContainersBytes: Int64, logsBytes: Int64, savedStateBytes: Int64, preferencesBytes: Int64,
         otherLibraryBytes: Int64) {
        self.name = name
        self.bundleID = bundleID
        self.path = path
        self.libraryPath = libraryPath
        self.components = components
        self.bundleBytes = bundleBytes
        self.applicationSupportBytes = applicationSupportBytes
        self.cachesBytes = cachesBytes
        self.containersBytes = containersBytes
        self.groupContainersBytes = groupContainersBytes
        self.logsBytes = logsBytes
        self.savedStateBytes = savedStateBytes
        self.preferencesBytes = preferencesBytes
        self.otherLibraryBytes = otherLibraryBytes
    }
}

/// Analyzes installed applications and their related storage across the user
/// library. Also detects "leftovers": library data whose owning app is gone.
/// Matching uses bundle IDs plus conservative name heuristics — ambiguous
/// shared folders are never auto-classified as removable.
public struct AppAnalyzer: Sendable {
    public let home: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    public func analyze(progress: (@Sendable (String) -> Void)? = nil) async -> (apps: [AppFootprint], leftovers: [AppFootprint]) {
        let fm = FileManager.default
        let library = home.appendingPathComponent("Library", isDirectory: true)

        // Installed apps
        var appURLs: [URL] = []
        for dir in [URL(fileURLWithPath: "/Applications"),
                    home.appendingPathComponent("Applications"),
                    URL(fileURLWithPath: "/System/Applications")] {
            guard let contents = await ScanEngine.listDirectory(dir, keys: [], timeout: 10).contents else { continue }
            appURLs.append(contentsOf: contents.filter { $0.pathExtension.lowercased() == "app" })
        }
        appURLs = Array(Set(appURLs.map { $0.standardizedFileURL })).sorted { $0.lastPathComponent < $1.lastPathComponent }

        struct AppInfo { let url: URL; let name: String; let bid: String? }
        let infos: [AppInfo] = appURLs.map { url in
            let bundle = Bundle(url: url)
            let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? url.deletingPathExtension().lastPathComponent
            return AppInfo(url: url, name: name, bid: bundle?.bundleIdentifier)
        }

        // PF-5: list Group Containers ONCE for all apps — footprint used to
        // re-list it per app (~66 redundant listings, each a pool roundtrip).
        let groupContainerDirs = await ScanEngine.listDirectory(
            library.appendingPathComponent("Group Containers"), keys: [], timeout: 10).contents ?? []

        let apps: [AppFootprint] = await withTaskGroup(of: AppFootprint?.self) { group in
            var iterator = infos.makeIterator()
            var results: [AppFootprint] = []
            func spawnNext() {
                guard let info = iterator.next() else { return }
                group.addTask { [home] in
                    await AppAnalyzer(home: home).footprint(for: info.url, name: info.name, bid: info.bid,
                                                            groupContainerDirs: groupContainerDirs)
                }
            }
            for _ in 0..<min(8, infos.count) { spawnNext() }
            while let foot = await group.next() {
                if let foot = foot {
                    results.append(foot)
                    progress?(foot.name)
                }
                spawnNext()
            }
            return results
        }

        // Leftovers: library entries with no matching installed app
        let installedKeys = Set(infos.flatMap { info -> [String] in
            var keys = [info.name.lowercased()]
            if let bid = info.bid?.lowercased() {
                keys.append(bid)
                keys.append(contentsOf: bid.split(separator: ".").map(String.init))
                let comps = bid.split(separator: ".").dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
                if comps.count > 1 { keys.append(comps.joined(separator: "/").lowercased()) }
            }
            return keys.filter { $0.count >= 3 }
        })

        let roots = ["Application Support", "Caches", "Containers", "Logs", "Saved Application State", "WebKit", "HTTPStorages"]
        var candidateEntries: [URL] = []
        for rootName in roots {
            let rootURL = library.appendingPathComponent(rootName, isDirectory: true)
            let listing = await ScanEngine.listDirectory(rootURL, keys: [], timeout: 10)
            guard let entries = listing.contents else { continue }
            for entry in entries {
                let entryName = entry.lastPathComponent
                let lower = entryName.lowercased()
                if lower.hasPrefix(".") { continue }
                if lower.hasPrefix("com.apple.") || Self.systemLibraryNames.contains(lower) { continue }
                let matched = installedKeys.contains { key in
                    key == lower || lower.hasPrefix(key + " ") || lower.hasPrefix(key + ".") || lower.hasPrefix(key + "-")
                        || (key.count >= 4 && (lower.contains(key) || key.contains(lower)))
                }
                if matched { continue }
                candidateEntries.append(entry)
            }
        }

        // Size candidates concurrently: system-stalled directories pay the
        // enumeration timeout each (first encounter), and a sequential loop
        // would multiply that by every stalled location.
        let leftovers: [AppFootprint] = await withTaskGroup(of: AppFootprint?.self) { group in
            var iterator = candidateEntries.makeIterator()
            var results: [AppFootprint] = []
            func spawnNext() {
                guard let entry = iterator.next() else { return }
                group.addTask {
                    let bytes = await DirectorySizer.logicalSize(of: entry)
                    guard bytes > 0 else { return nil }
                    let entryName = entry.lastPathComponent
                    return AppFootprint(
                        name: entryName, bundleID: nil, path: "", libraryPath: entry.path,
                        components: [AppComponent(name: entryName, path: entry.path, bytes: bytes, kind: .other)],
                        bundleBytes: 0, applicationSupportBytes: 0, cachesBytes: 0, containersBytes: 0,
                        groupContainersBytes: 0, logsBytes: 0, savedStateBytes: 0, preferencesBytes: 0,
                        otherLibraryBytes: bytes
                    )
                }
            }
            for _ in 0..<min(8, candidateEntries.count) { spawnNext() }
            while let foot = await group.next() {
                if let foot = foot { results.append(foot) }
                spawnNext()
            }
            return results
        }

        return (apps.sorted { $0.totalBytes > $1.totalBytes },
                leftovers.sorted { $0.totalBytes > $1.totalBytes })
    }

    /// Removes apps whose bundle was trashed and leftovers whose data was
    /// trashed, so the UI reflects a completed uninstall immediately instead
    /// of showing stale entries until the next full app analysis.
    /// (A partially trashed app — data only, bundle intact — stays listed;
    /// its sizes refresh on the next "Re-analyze".)
    public static func removingTrashed(apps: [AppFootprint], leftovers: [AppFootprint],
                                       trashedPaths: Set<String>) -> (apps: [AppFootprint], leftovers: [AppFootprint]) {
        let trashed = Set(trashedPaths.map { PathKit.normalize($0) })
        let keptApps = apps.filter { app in
            app.path.isEmpty || !trashed.contains(PathKit.normalize(app.path))
        }
        let keptLeftovers = leftovers.filter { leftover in
            let paths = [leftover.libraryPath] + leftover.components.map(\.path)
            return !paths.contains { trashed.contains(PathKit.normalize($0)) }
        }
        return (keptApps, keptLeftovers)
    }

    func footprint(for url: URL, name: String, bid: String?,
                   groupContainerDirs: [URL]? = nil) async -> AppFootprint? {
        let fm = FileManager.default
        let library = home.appendingPathComponent("Library", isDirectory: true)
        let bidKey = bid?.lowercased()
        let nameKey = name.lowercased()
        // SV-1: an unreadable bundle ID must never fall back to "" — that
        // collapses every bid-keyed path onto the Library folder ROOT
        // (~/Library/Application Support, Caches, …), offering whole Library
        // folders as uninstall components. Bid-keyed components exist only
        // when the bundle ID is real; name-based fallbacks remain.
        let bidValue = (bid?.isEmpty == false) ? bid! : nil

        func size(_ path: String) async -> Int64 {
            guard fm.fileExists(atPath: path) else { return 0 }
            return await DirectorySizer.logicalSize(of: URL(fileURLWithPath: path))
        }

        var components: [AppComponent] = []
        func addComponent(_ name: String, _ path: String, _ kind: AppComponent.Kind) async -> Int64 {
            guard fm.fileExists(atPath: path) else { return 0 }
            let bytes = await size(path)
            guard bytes > 0 else { return 0 }
            components.append(AppComponent(name: name, path: path, bytes: bytes, kind: kind))
            return bytes
        }

        var support: Int64 = 0, caches: Int64 = 0, containers: Int64 = 0, group: Int64 = 0, logs: Int64 = 0,
            saved: Int64 = 0, prefs: Int64 = 0, other: Int64 = 0

        let bundleBytes = await addComponent(name, url.path, .bundle)

        // Application Support: bundle ID first, then app name (name fallback is root-safe)
        if let bidValue {
            support += await addComponent("Application Support", library.appendingPathComponent("Application Support/\(bidValue)").path, .applicationSupport)
        }
        if support == 0 && !nameKey.isEmpty {
            support += await addComponent("Application Support", library.appendingPathComponent("Application Support/\(name)").path, .applicationSupport)
        }

        if let bidValue {
            caches += await addComponent("Caches", library.appendingPathComponent("Caches/\(bidValue)").path, .caches)
        }
        if caches == 0 {
            caches += await addComponent("Caches", library.appendingPathComponent("Caches/\(nameKey)").path, .caches)
        }
        if caches == 0, bidKey?.split(separator: ".").count ?? 0 > 2 {
            let comps = bidKey!.split(separator: ".").dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
            caches += await addComponent("Caches", library.appendingPathComponent("Caches/" + comps.joined(separator: "/")).path, .caches)
        }

        if let bidValue {
            containers += await addComponent("Containers", library.appendingPathComponent("Containers/\(bidValue)").path, .containers)
            logs += await addComponent("Logs", library.appendingPathComponent("Logs/\(bidValue)").path, .logs)
            saved += await addComponent("Saved State", library.appendingPathComponent("Saved Application State/\(bidValue).savedState").path, .savedState)
            prefs += await addComponent("Preferences", library.appendingPathComponent("Preferences/\(bidValue).plist").path, .preferences)
            other += await addComponent("WebKit Data", library.appendingPathComponent("WebKit/\(bidValue)").path, .other)
            other += await addComponent("HTTP Storage", library.appendingPathComponent("HTTPStorages/\(bidValue)").path, .other)
        }

        // Group containers match by bundle-ID substring
        if let bidKey {
            let groupDirs: [URL]
            if let groupContainerDirs {
                groupDirs = groupContainerDirs
            } else {
                let gcRoot = library.appendingPathComponent("Group Containers")
                groupDirs = await ScanEngine.listDirectory(gcRoot, keys: [], timeout: 10).contents ?? []
            }
            for dir in groupDirs where dir.lastPathComponent.lowercased().contains(bidKey) {
                group += await addComponent("Group Container", dir.path, .groupContainers)
            }
        }

        guard bundleBytes + support + caches + containers + group + logs + saved + prefs + other > 0 else { return nil }

        return AppFootprint(
            name: name, bundleID: bid, path: url.path, libraryPath: "", components: components,
            bundleBytes: bundleBytes, applicationSupportBytes: support, cachesBytes: caches,
            containersBytes: containers, groupContainersBytes: group, logsBytes: logs,
            savedStateBytes: saved, preferencesBytes: prefs, otherLibraryBytes: other
        )
    }

    static let systemLibraryNames: Set<String> = [
        "addressbook", "autosave information", "callhistory", "containers", "crashreporter",
        "diagnostics", "dock", "faceTime", "group containers", "icloud", "knowledge",
        "metadata", "mobilesync", "preferences", "safari", "suggestions", "syncservices",
        "systemgroup", "accounts", "assistantservices", "continuity", "apple", "webkit",
        "httpstorages", "logs", "caches", "application support", "saved application state",
        "textedit", "preview", "ffmpeg", "homekit", "siri", "shortcuts", "spotlight",
    ]
}
