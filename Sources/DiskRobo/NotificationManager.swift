import Foundation
import UserNotifications
import RoboCore

/// Local system notifications (no network, no content — product-level alerts only).
/// macOS asks the user for permission once; if denied, alerts degrade silently
/// to the in-app Insights feed.
final class NotificationManager: @unchecked Sendable {
    static let shared = NotificationManager()
    private let center = UNUserNotificationCenter.current()
    private var authChecked = false

    func requestAuthorizationIfNeeded() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            let granted = (try? await center.requestAuthorization(options: [.alert])) ?? false
            authChecked = true
            return granted
        default:
            return false
        }
    }

    /// Threshold alerts after a scan: free-space pressure + top radar finding.
    func postScanAlerts(freeBytes: Int64?, freeWarningBytes: Int64, findings: [RadarFinding]) {
        Task {
            guard await requestAuthorizationIfNeeded() else { return }

            if let free = freeBytes, free < freeWarningBytes {
                notify(
                    title: "Disk Robo — free space is low",
                    body: "Only \(Format.bytes(free)) free. Quick Clean can recover safe, regenerable space.")
            }

            if let top = findings.first(where: { $0.severity >= 4 }) {
                notify(
                    title: "Disk Robo Radar — \(top.title)",
                    body: top.recommendation)
            }
        }
    }

    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(request)
    }
}
