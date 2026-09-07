import SwiftUI
import RoboCore

// MARK: - Theme v2 (dark dashboard)

enum Theme {
    /// Card / panel surfaces on the dark dashboard.
    static let cardFill = Color(nsColor: .underPageBackgroundColor)
    static let panelFill = Color(nsColor: .underPageBackgroundColor).opacity(0.7)
    static let cardStroke = Color.white.opacity(0.07)
    static let appBackground = Color(nsColor: .windowBackgroundColor)

    static func color(for category: StorageCategory) -> Color {
        switch category {
        case .applications: return Color(red: 0.30, green: 0.56, blue: 1.00)   // blue
        case .developer: return Color(red: 0.42, green: 0.72, blue: 0.55)      // teal-green
        case .caches: return .cyan
        case .downloads: return .orange
        case .trash: return Color(nsColor: .systemGray)
        case .installers: return Color(red: 0.95, green: 0.45, blue: 0.45)     // red-pink
        case .archives: return .brown
        case .logs: return .teal
        case .browser: return .green
        case .media: return .pink
        case .documents: return Color(red: 0.95, green: 0.62, blue: 0.26)      // amber
        case .system: return Color(red: 0.62, green: 0.51, blue: 0.92)         // purple
        case .other: return Color(nsColor: .systemGray).opacity(0.75)
        }
    }

    static func color(for risk: RiskLevel) -> Color {
        switch risk {
        case .green: return .green
        case .yellow: return .yellow
        case .orange: return .orange
        case .red: return .red
        }
    }

    static func color(for severity: InsightSeverity) -> Color {
        switch severity {
        case .info: return Color.accentColor
        case .success: return .green
        case .warning: return .orange
        case .critical: return .red
        }
    }
}

// MARK: - Dashboard card container

struct DashboardCard<Content: View>: View {
    var title: String?
    var subtitle: String?
    var trailing: AnyView? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.headline)
                        if let subtitle {
                            Text(subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    trailing
                }
            }
            content
        }
        .padding(16)
        .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.cardStroke))
    }
}

// MARK: - Risk badge (never color-only: symbol + label always present)

struct RiskBadge: View {
    let risk: RiskLevel
    var body: some View {
        Label(risk.displayName, systemImage: risk.symbolName)
            .font(.caption.weight(.medium))
            .foregroundStyle(Theme.color(for: risk))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Theme.color(for: risk).opacity(0.12), in: Capsule())
            .accessibilityLabel("Risk: \(risk.displayName)")
    }
}

struct ConfidenceLabel: View {
    let confidence: Confidence
    var body: some View {
        Text("Confidence: \(confidence.displayName)")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

/// "Phase 2" marker for preview features — honest labeling, no fake UI.
struct SoonBadge: View {
    var body: some View {
        Text("Soon")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.orange)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.orange.opacity(0.12), in: Capsule())
    }
}

// MARK: - Stat card

struct StatCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    init(title: String, systemImage: String = "chart.pie.fill", @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: systemImage).font(.title3).foregroundStyle(Color.accentColor)
                Text(title).font(.headline)
            }
            content.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.cardStroke))
    }
}

// MARK: - Segmented usage bar

struct UsageBar: View {
    let segments: [(Color, Double)]
    var height: CGFloat = 10

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 1.5) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    Rectangle()
                        .fill(segment.0)
                        .frame(width: geo.size.width * segment.1)
                }
            }
        }
        .frame(height: height)
        .clipShape(Capsule())
        .accessibilityHidden(true)
    }
}

// MARK: - Health ring

struct HealthRing: View {
    let score: Int?
    let size: CGFloat
    var lineWidth: CGFloat? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var ringColor: Color {
        guard let score else { return Color(nsColor: .systemGray) }
        switch score {
        case ..<25: return .red
        case ..<50: return .orange
        case ..<75: return .yellow
        default: return .green
        }
    }

    var body: some View {
        ZStack {
            Circle().stroke(ringColor.opacity(0.18), lineWidth: lineWidth ?? size * 0.082)
            Circle()
                .trim(from: 0, to: Double(score ?? 0) / 100)
                .stroke(ringColor, style: StrokeStyle(lineWidth: lineWidth ?? size * 0.082, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(reduceMotion ? nil : .easeInOut(duration: 1.2), value: score)
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(score.map { "Disk health \($0) of 100" } ?? "Disk health not yet measured")
    }
}

/// Small green pulse used in the status bar ("scan healthy").
struct StatusDot: View {
    let color: Color
    var body: some View {
        Circle()
            .fill(color.opacity(0.25))
            .frame(width: 22, height: 22)
            .overlay(Circle().fill(color).frame(width: 9, height: 9))
    }
}

// MARK: - Robo Core (animated health ring; respects reduce-motion)

struct RoboCoreView: View {
    let health: Int?
    let scanning: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var ringColor: Color {
        if scanning { return .indigo }
        switch health ?? 50 {
        case ..<25: return .red
        case ..<50: return .orange
        case ..<75: return .yellow
        default: return .green
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(ringColor.opacity(0.18), lineWidth: 9)
            Circle()
                .trim(from: 0, to: scanning ? 0.75 : Double(health ?? 0) / 100)
                .stroke(ringColor, style: StrokeStyle(lineWidth: 9, lineCap: .round, dash: scanning ? [6, 5] : []))
                .rotationEffect(.degrees(-90))
                .animation(reduceMotion ? nil : .easeInOut(duration: 1.2), value: health)
        }
        .frame(width: 110, height: 110)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(scanning ? "Scanning storage" : "Disk health \(health ?? 0) of 100")
    }
}

// MARK: - Empty / error states

struct ScanPromptView: View {
    let title: String
    let message: String
    var actionTitle: String = "Scan My Home"
    var quickActionTitle: String? = "Quick Scan"
    var onScan: () -> Void
    var onQuickScan: (() -> Void)? = nil

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "externaldrive.badge.timemachine")
        } description: {
            Text(message)
        } actions: {
            HStack {
                Button(actionTitle, action: onScan).buttonStyle(.borderedProminent)
                if let quickActionTitle, let onQuickScan {
                    Button(quickActionTitle, action: onQuickScan).buttonStyle(.bordered)
                }
            }
        }
    }
}

// MARK: - App icon helper (Top Consumers)

struct AppIconView: View {
    let path: String
    var size: CGFloat = 26

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: path))
            .resizable()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
    }
}

// MARK: - Labeled row (detail panels)

struct LabeledRow: View {
    let label: String
    let value: String
    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }
    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.callout)
    }
}

// MARK: - Scan progress card

struct ScanProgressCard: View {
    let progress: ScanProgress?
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Scanning…", systemImage: "magnifyingglass")
                    .font(.headline)
                Spacer()
                Button("Cancel", role: .destructive, action: onCancel).controlSize(.small)
            }
            if let p = progress {
                HStack(spacing: 16) {
                    stat("\(p.filesSeen)", label: "files")
                    stat("\(p.directoriesSeen)", label: "folders")
                    stat(p.bytesSeen.bytesFormatted, label: "seen")
                    stat(String(format: "%.0fs", p.elapsed), label: "elapsed")
                }
                Text(p.currentPath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            } else {
                Text("Preparing…").font(.caption).foregroundStyle(.secondary)
            }
            ProgressView().controlSize(.small)
        }
        .padding(16)
        .background(Color.indigo.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.indigo.opacity(0.3)))
    }

    private func stat(_ value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.subheadline.weight(.medium).monospacedDigit())
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Size formatting

extension Int64 {
    var bytesFormatted: String { Format.bytes(self) }
}
