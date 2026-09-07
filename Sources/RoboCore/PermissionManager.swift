import Foundation

public struct FullDiskAccessStatus: Sendable, Equatable {
    public let granted: Bool
    public let detail: String
}

/// Probes Full Disk Access honestly by attempting to list TCC-protected
/// locations. Never guesses, never works around TCC.
///
/// The probes go through the `EnumerationWorkers` watchdog pool: a
/// TCC-protected directory can block `open()` forever on affected machines,
/// and a synchronous probe would beachball the caller (SV-3).
public struct PermissionManager: Sendable {
    private let probes: [URL]

    public init(probes: [URL]? = nil) {
        if let probes {
            self.probes = probes
        } else {
            let fm = FileManager.default
            self.probes = [
                fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Safari"),
                URL(fileURLWithPath: "/Library/Application Support/MobileSync"),
            ]
        }
    }

    public func checkFullDiskAccess(probeTimeout: TimeInterval = 2) async -> FullDiskAccessStatus {
        let fm = FileManager.default
        for probe in probes where fm.fileExists(atPath: probe.path) {
            let listing = await ScanEngine.listDirectory(probe, keys: [], timeout: probeTimeout)
            if listing.contents != nil {
                return FullDiskAccessStatus(granted: true, detail: "Full Disk Access is granted.")
            }
        }
        return FullDiskAccessStatus(
            granted: false,
            detail: "Full Disk Access was not detected. Disk Robo can still scan most of your home folder; protected locations will be reported as inaccessible — never estimated."
        )
    }

    public static let fullDiskAccessSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
}
