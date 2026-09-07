import SwiftUI
import RoboCore

/// First-launch onboarding: honest explanation of what Disk Robo does and why
/// Full Disk Access is useful (never required, never bypassed).
struct OnboardingScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var page = 0

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            content
            Spacer()
            controls
        }
        .frame(width: 620, height: 430)
        .background(.regularMaterial)
    }

    private var content: some View {
        VStack(spacing: 18) {
            Image(systemName: "externaldrive.badge.timemachine")
                .font(.system(size: 46))
                .foregroundStyle(Color.accentColor)

            switch page {
            case 0:
                VStack(spacing: 10) {
                    Text("Meet your storage engineer").font(.title.weight(.semibold))
                    Text("Disk Robo doesn't just show what uses disk space. It explains why storage is consumed, what is safe to remove, what happens if you do, and how your disk changes over time.")
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 460)
                }
            case 1:
                VStack(spacing: 10) {
                    Text("Safety first — always").font(.title.weight(.semibold))
                    VStack(alignment: .leading, spacing: 8) {
                        bullet("checkmark.seal", "Every cleanup item is risk-classified: Safe, Review, Important, or Protected.")
                        bullet("trash", "Deleting means moving to the Trash — Disk Robo never permanently deletes or empties your Trash.")
                        bullet("lock.shield", "System files, Mail, Messages, iCloud Drive, and similar locations are hard-protected and can never be touched.")
                        bullet("eye", "Nothing happens without a preview and your explicit approval.")
                    }
                }
            default:
                VStack(spacing: 10) {
                    Text("One permission, honestly explained").font(.title.weight(.semibold))
                    Text("Full Disk Access allows Disk Robo to measure storage used by applications and protected user-library locations. Without it, those folders show as “inaccessible” — never estimated, never guessed.")
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 480)
                    Text("Disk Robo does not upload scanned file information. It contains no networking code at all — every byte of analysis happens on this Mac.")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: 460)
                }
            }
        }
        .padding(.horizontal, 30)
    }

    private func bullet(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.green).frame(width: 18)
            Text(text).font(.callout).multilineTextAlignment(.leading)
        }
        .frame(maxWidth: 440, alignment: .leading)
    }

    private var controls: some View {
        HStack {
            if page > 0 {
                Button("Back") { page -= 1 }
            }
            Spacer()
            if model.fdaStatus?.granted != true && page == 2 {
                Button("Open System Settings") {
                    openURL(PermissionManager.fullDiskAccessSettingsURL)
                }
            }
            if page < 2 {
                Button("Continue") { page += 1 }
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Get Started") {
                    model.completeOnboarding()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
    }
}
