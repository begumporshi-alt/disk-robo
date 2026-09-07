import Foundation

public struct AppSettings: Codable, Sendable, Equatable {
    public var onboardingCompleted = false
    public var excludedPaths: [String] = []
    public var freeSpaceWarningGB: Int = 15
    public var duplicateMinSizeMB: Int = 1
    public var snapshotRetention: Int = 120
    public var autoSnapshot: Bool = true
    /// System notifications for free-space pressure and radar findings.
    public var notificationsEnabled: Bool = true
    /// Gentle scan mode: 2 walkers instead of 8, background priority — for
    /// battery use (adds ~10-20% scan time).
    public var scanGentleMode: Bool = false
    /// Tier 4: scan in the DiskRoboScanner child process so scan memory
    /// returns to the OS when the child exits. Falls back to in-process
    /// scanning when off or when the executable is missing.
    public var scanInChildProcess: Bool = true

    public init() {}

    /// Tolerant decoding: fields added after the first release default cleanly
    /// instead of failing the whole decode (which would reset onboarding state).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        onboardingCompleted = try c.decodeIfPresent(Bool.self, forKey: .onboardingCompleted) ?? false
        excludedPaths = try c.decodeIfPresent([String].self, forKey: .excludedPaths) ?? []
        freeSpaceWarningGB = try c.decodeIfPresent(Int.self, forKey: .freeSpaceWarningGB) ?? 15
        duplicateMinSizeMB = try c.decodeIfPresent(Int.self, forKey: .duplicateMinSizeMB) ?? 1
        snapshotRetention = try c.decodeIfPresent(Int.self, forKey: .snapshotRetention) ?? 120
        autoSnapshot = try c.decodeIfPresent(Bool.self, forKey: .autoSnapshot) ?? true
        notificationsEnabled = try c.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? true
        scanGentleMode = try c.decodeIfPresent(Bool.self, forKey: .scanGentleMode) ?? false
        scanInChildProcess = try c.decodeIfPresent(Bool.self, forKey: .scanInChildProcess) ?? true
    }
}

/// UserDefaults-backed settings store.
public final class SettingsStore: @unchecked Sendable {
    private let key = "diskrobo.settings.v1"
    private let defaults: UserDefaults
    private let lock = NSLock()
    public private(set) var settings: AppSettings

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            self.settings = decoded
        } else {
            self.settings = AppSettings()
        }
    }

    public func update(_ mutate: (inout AppSettings) -> Void) {
        lock.lock(); defer { lock.unlock() }
        mutate(&settings)
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: key)
        }
    }

    /// Paths always excluded from Disk Robo's own scans.
    public static func builtInExclusions() -> [String] {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return [support.appendingPathComponent("DiskRobo").path]
    }
}
