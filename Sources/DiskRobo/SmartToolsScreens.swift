import SwiftUI
import Charts
import RoboCore

// MARK: - Robo Radar (engine-driven)

struct RadarScreen: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                DashboardCard(title: "Robo Radar",
                              subtitle: "Storage anomalies, ranked by severity × recoverable × confidence × recurrence") {
                    if model.radarFindings.isEmpty {
                        if model.scanResult == nil {
                            VStack(spacing: 10) {
                                Text("Radar works from your scan data — no scan yet.")
                                    .font(.callout).foregroundStyle(.secondary)
                                Button("Scan My Home") { model.startFullScan() }
                                    .buttonStyle(.borderedProminent)
                            }
                            .padding(.vertical, 14)
                        } else {
                            ContentUnavailableView("All clear",
                                                   systemImage: "checkmark.seal",
                                                   description: Text("No storage anomalies detected in the current scan and history."))
                                .padding(.vertical, 12)
                        }
                    } else {
                        VStack(spacing: 10) {
                            ForEach(model.radarFindings) { finding in
                                findingRow(finding)
                            }
                        }
                    }
                }

                if !model.offenders.isEmpty {
                    DashboardCard(title: "Repeat Offenders",
                                  subtitle: "Cleaned before, grown back — the recurring costs of your apps") {
                        ForEach(model.offenders.prefix(6)) { offender in
                            offenderRow(offender)
                        }
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle("Robo Radar")
    }

    private func findingRow(_ finding: RadarFinding) -> some View {
        HStack(alignment: .top, spacing: 12) {
            severityBadge(finding.severity)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(finding.title).font(.callout.weight(.semibold))
                    if let recoverable = finding.recoverableBytes {
                        Text("≈\(recoverable.bytesFormatted) recoverable")
                            .font(.caption.weight(.medium)).foregroundStyle(.green)
                    }
                }
                Text(finding.detail).font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Text(finding.recommendation).font(.caption)
                    Text("·").font(.caption).foregroundStyle(.tertiary)
                    Text("Confidence: \(finding.confidence.displayName)").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
            findingAction(finding)
        }
        .padding(12)
        .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))
    }

    /// Every finding links to the screen where its recommendation can be acted
    /// on — a recommendation you can't reach is a dead end.
    @ViewBuilder
    private func findingAction(_ finding: RadarFinding) -> some View {
        switch finding.kind {
        case .freeSpace, .cacheBloat, .repeatOffender, .installerBuildup:
            actionLink("Review in Cleanup") { model.selectedSection = .cleanup }
        case .rapidGrowth, .bigGrower:
            actionLink("Open Growth Tracker") { model.selectedSection = .growth }
        case .duplicateMass:
            actionLink("Review Duplicates") { model.selectedSection = .duplicates }
        case .leftovers:
            actionLink("Review Leftovers") { model.selectedSection = .uninstaller }
        case .trashBuildup:
            actionLink("Open Trash") {
                let trash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
                NSWorkspace.shared.open(trash)
            }
        }
    }

    private func actionLink(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.caption.weight(.medium))
        }
        .buttonStyle(.link)
        .controlSize(.small)
    }

    private func severityBadge(_ severity: Int) -> some View {
        VStack(spacing: 2) {
            Image(systemName: severity >= 5 ? "exclamationmark.octagon.fill"
                : severity >= 4 ? "exclamationmark.triangle.fill"
                : severity >= 3 ? "circle.fill" : "circle")
                .font(.system(size: 16))
                .foregroundStyle(severityColor(severity))
            Text("S\(severity)").font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary)
        }
        .frame(width: 30)
    }

    private func severityColor(_ severity: Int) -> Color {
        switch severity {
        case 5: return .red
        case 4: return .orange
        case 3: return .yellow
        default: return .secondary
        }
    }

    private func offenderRow(_ offender: RepeatOffender) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(offender.displayName).font(.callout.weight(.medium))
                Text("Cleaned \(offender.cleanedBytes.bytesFormatted) on \(offender.lastCleaned.formatted(date: .abbreviated, time: .omitted)) · regrown to \(offender.currentBytes.bytesFormatted)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let weekly = offender.weeklyGrowthBytes, weekly > 0 {
                Text(String(format: "~%.1f GB/week", weekly / 1_000_000_000))
                    .font(.caption.monospacedDigit()).foregroundStyle(.orange)
            }
            Button("Clean Again") { model.selectedSection = .cleanup }
                .buttonStyle(.link)
                .controlSize(.small)
        }
        .padding(10)
        .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Robo Assistant (chat)

struct AssistantScreen: View {
    @Environment(AppModel.self) private var model
    @State private var input = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            transcript
            inputBar
        }
        .navigationTitle("Robo Assistant")
        .onAppear {
            if model.assistantMessages.isEmpty {
                model.assistantMessages.append(AppModel.ChatMessage(
                    isUser: false,
                    text: "Hi — I'm Disk Robo's on-device assistant. Every answer comes from your local scan data, and nothing leaves this Mac. Ask me why your disk is full, what's safe to clean, or what an app is hiding.",
                    suggestions: ["Why is my disk full?", "Can I safely free 20 GB?", "What grew since yesterday?"]))
            }
            inputFocused = true
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(model.assistantMessages) { message in
                        MessageBubble(message: message) { suggestion in
                            model.sendAssistant(suggestion)
                        }
                            .id(message.id)
                    }
                }
                .padding(18)
            }
            .onChange(of: model.assistantMessages.count) { _, _ in
                if let last = model.assistantMessages.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "brain.head.profile").foregroundStyle(Color.accentColor)
            TextField("Ask about your storage…", text: $input)
                .textFieldStyle(.plain)
                .onSubmit(send)
                .focused($inputFocused)
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill").font(.title2)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Send message")
            .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Theme.cardFill)
        .overlay(Divider(), alignment: .top)
    }

    private func send() {
        let text = input
        input = ""
        model.sendAssistant(text)
    }
}

struct MessageBubble: View {
    let message: AppModel.ChatMessage
    let onSuggestion: (String) -> Void

    var body: some View {
        VStack(alignment: message.isUser ? .trailing : .leading, spacing: 8) {
            if !message.isUser {
                HStack(spacing: 6) {
                    Image(systemName: "brain.head.profile")
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                    Text("Robo").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text("· on-device").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Text(message.text)
                .font(.callout)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    message.isUser
                        ? AnyShapeStyle(Color.accentColor.opacity(0.22))
                        : AnyShapeStyle(Theme.cardFill),
                    in: RoundedRectangle(cornerRadius: 14)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14).strokeBorder(
                        message.isUser ? Color.accentColor.opacity(0.3) : Theme.cardStroke)
                )
                .frame(maxWidth: 560, alignment: message.isUser ? .trailing : .leading)
            if !message.isUser && !message.suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(message.suggestions, id: \.self) { suggestion in
                        Button {
                            onSuggestion(suggestion)
                        } label: {
                            Text(suggestion)
                                .font(.caption)
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(Color.accentColor.opacity(0.10), in: Capsule())
                                .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.25)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: message.isUser ? .trailing : .leading)
    }
}

// MARK: - Growth Tracker (+ forecast)

struct GrowthTrackerScreen: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.snapshots.count < 2 {
                ContentUnavailableView("Not enough history yet",
                                       systemImage: "chart.line.uptrend.xyaxis",
                                       description: Text("Disk Robo saves a snapshot after every full scan. Run two scans (today and in a few days) and this screen will show exactly where your space went."))
            } else {
                content
            }
        }
        .navigationTitle("Growth Tracker")
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let forecast = model.forecast {
                    forecastCard(forecast)
                }
                usageChart
                if let delta = model.growthDelta {
                    GrowthDiffView(delta: delta)
                }
            }
            .padding(20)
        }
    }

    private func forecastCard(_ forecast: StorageForecast) -> some View {
        DashboardCard(title: "Storage Forecast",
                      subtitle: "Ordinary least squares over snapshot history — confidence shown honestly") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 18) {
                    if let days = forecast.daysUntilLowFree {
                        stat(value: "\(days)", label: "days below \(model.settings.settings.freeSpaceWarningGB) GB free", color: .orange)
                    }
                    stat(value: String(format: "%.1f GB", abs(forecast.weeklyGrowthBytes) / 1_000_000_000),
                         label: forecast.weeklyGrowthBytes > 0 ? "lost per week" : "gained per week",
                         color: forecast.weeklyGrowthBytes > 0 ? .red : .green)
                    stat(value: forecast.confidence.displayName, label: "confidence", color: .secondary)
                }
                Text(forecast.narrative).font(.callout)
                if let projected = forecast.projectedFreeBytesIn30Days {
                    Text("Projected free space in 30 days: \(projected.bytesFormatted) (fit R² = \(String(format: "%.2f", forecast.rSquared))).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 260)
    }

    private func stat(value: String, label: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(.title3, design: .rounded).weight(.bold)).monospacedDigit().foregroundStyle(color)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var usageChart: some View {
        DashboardCard(title: "Storage Over Time",
                      subtitle: "Scanned bytes after each full scan") {
            Chart(fullSnapshots) { snapshot in
                LineMark(
                    x: .value("Date", snapshot.date),
                    y: .value("Used GB", Double(snapshot.usedBytes) / 1_000_000_000)
                )
                .foregroundStyle(Color.accentColor)
                .interpolationMethod(.catmullRom)

                AreaMark(
                    x: .value("Date", snapshot.date),
                    y: .value("Used GB", Double(snapshot.usedBytes) / 1_000_000_000)
                )
                .foregroundStyle(LinearGradient(colors: [Color.accentColor.opacity(0.25), .clear],
                                                startPoint: .top, endPoint: .bottom))
                .interpolationMethod(.catmullRom)

                PointMark(
                    x: .value("Date", snapshot.date),
                    y: .value("Used GB", Double(snapshot.usedBytes) / 1_000_000_000)
                )
                .foregroundStyle(Color.accentColor)
            }
            .chartYAxis {
                AxisMarks(position: .leading)
            }
            .frame(height: 220)
        }
    }

    private var fullSnapshots: [Snapshot] { model.snapshots.filter { !$0.isQuickScan } }
}

// MARK: - Uninstaller (real flow)

struct UninstallerScreen: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var selectedApp: AppFootprint?
    @State private var includedComponents: Set<String> = []
    @State private var confirmTrash = false
    @State private var selectedLeftoverIDs: Set<String> = []
    @State private var confirmLeftoverTrash = false

    private var visibleApps: [AppFootprint] {
        search.isEmpty ? model.apps : model.apps.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        Group {
            if model.apps.isEmpty && model.leftovers.isEmpty {
                ScanPromptView(
                    title: "Uninstall apps completely",
                    message: "Disk Robo measures every app's full footprint first — then you choose exactly what to remove. Everything goes to the Trash, safety-checked.",
                    actionTitle: "Analyze Apps",
                    quickActionTitle: nil,
                    onScan: { model.analyzeApps() },
                    onQuickScan: nil
                )
            } else {
                content
            }
        }
        .navigationTitle("Uninstaller")
        // UI-4: reconcile the selection when the model's data mutates (a
        // completed uninstall prunes the arrays) — the detail pane must never
        // keep showing an app that no longer exists.
        .onChange(of: model.apps) { _, newApps in
            selectedApp = selectedApp.flatMap { sel in newApps.first { $0.id == sel.id } }
        }
        .onChange(of: model.leftovers) { _, newLeftovers in
            if let sel = selectedLeftoverIDs.first,
               !newLeftovers.contains(where: { $0.id == sel }) {
                selectedLeftoverIDs.remove(sel)
            }
            selectedLeftoverIDs.formIntersection(Set(newLeftovers.map(\.id)))
        }
        .alert("Move \(selectedComponentCount) item(s) to the Trash?", isPresented: $confirmTrash) {
            Button("Move to Trash", role: .destructive) { trashSelected() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removing an app's bundle uninstalls it. Library data goes to the Trash too — recoverable until you empty it. Protected locations (containers, keychains) are vetoed by the safety engine and will be reported.")
        }
        .alert("Move \(selectedLeftoverCount) leftover item(s) to the Trash?", isPresented: $confirmLeftoverTrash) {
            Button("Move to Trash", role: .destructive) { trashLeftovers() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Leftover data belongs to apps that are no longer installed — it is usually safe to remove. Shared folder names can be ambiguous, so check the path first. Everything goes to the Trash and is safety-checked; protected locations are vetoed and reported.")
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                List(selection: $selectedApp) {
                    Section("Installed — \(visibleApps.count)") {
                        ForEach(visibleApps) { app in
                            HStack(spacing: 9) {
                                AppIconView(path: app.path, size: 22)
                                Text(app.name).lineLimit(1)
                                Spacer()
                                Text(app.totalBytes.bytesFormatted).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            .tag(app)
                        }
                    }
                }
                .listStyle(.sidebar)
                .frame(width: 260)
                .safeAreaInset(edge: .top, spacing: 0) {
                    TextField("Search apps…", text: $search)
                        .textFieldStyle(.roundedBorder)
                        .padding(8)
                        .overlay(Divider(), alignment: .bottom)
                }

                Divider()

                detailPane
            }

            if let outcome = model.executionOutcome {
                OutcomeBanner(outcome: outcome) { model.executionOutcome = nil }
            }
        }
    }

    /// Right pane: the selected app's component review plus the leftover-removal
    /// card (leftovers are removable regardless of which app is selected).
    private var detailPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let app = selectedApp {
                    appComponentsCard(app)
                } else if model.leftovers.isEmpty {
                    ContentUnavailableView("Select an application",
                                           systemImage: "trash.slash",
                                           description: Text("Choose an app to see every file it owns — bundle, support data, caches, containers, logs."))
                }
                if !model.leftovers.isEmpty {
                    leftoversCard
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { syncComponentSelection() }
        .onChange(of: selectedApp) { _, _ in syncComponentSelection() }
    }

    private func syncComponentSelection() {
        guard let app = selectedApp else { return }
        includedComponents = Set(app.components.filter { $0.kind != .bundle }.map(\.path))
    }

    private func appComponentsCard(_ app: AppFootprint) -> some View {
        DashboardCard(title: app.name,
                      subtitle: "\(app.totalBytes.bytesFormatted) total · bundleID \(app.bundleID ?? "unknown")") {
            if app.components.isEmpty {
                Text("No removable components found for this app.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 2) {
                    ForEach(app.components) { component in
                        componentRow(component)
                    }
                }
                Divider()
                HStack {
                    Text("\(selectedComponentCount) selected · \(selectedComponentBytes.bytesFormatted)")
                        .font(.callout.monospacedDigit())
                    Spacer()
                    Button("Select All") {
                        includedComponents = Set(app.components.map(\.path))
                    }
                    .controlSize(.small)
                    Button("Move Selected to Trash…", role: .destructive) {
                        confirmTrash = true
                    }
                    .buttonStyle(.borderedProminent).tint(.red)
                    .disabled(selectedComponentCount == 0)
                }
            }
        }
    }

    // MARK: Leftovers (removal flow — user-initiated, safety-checked)

    private var leftoversCard: some View {
        DashboardCard(title: "Leftovers from removed apps",
                      subtitle: "Data whose app is no longer installed — select to remove") {
            LazyVStack(spacing: 2) {
                ForEach(model.leftovers) { leftover in
                    leftoverRow(leftover)
                }
                if !selectedLeftoverIDs.isEmpty {
                    Divider()
                    HStack {
                        Text("\(selectedLeftoverCount) selected · \(selectedLeftoverBytes.bytesFormatted)")
                            .font(.callout.monospacedDigit())
                        Spacer()
                        Button("Move Selected to Trash…", role: .destructive) {
                            confirmLeftoverTrash = true
                        }
                        .buttonStyle(.borderedProminent).tint(.red)
                    }
                }
            }
        }
    }

    private func leftoverRow(_ leftover: AppFootprint) -> some View {
        let included = selectedLeftoverIDs.contains(leftover.id)
        return HStack(spacing: 10) {
            Button {
                if included {
                    selectedLeftoverIDs.remove(leftover.id)
                } else {
                    selectedLeftoverIDs.insert(leftover.id)
                }
            } label: {
                Image(systemName: included ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(included ? Color.red : Color.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(leftover.name), \(leftover.totalBytes.bytesFormatted)")
            .accessibilityValue(included ? "selected for removal" : "not selected")

            VStack(alignment: .leading, spacing: 1) {
                Text(leftover.name).font(.callout.weight(.medium)).lineLimit(1)
                Text(leftover.libraryPath).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(leftover.totalBytes.bytesFormatted).font(.callout.monospacedDigit())
            if leftover.libraryPath.lowercased().contains("group containers") {
                RiskBadge(risk: .red)
            } else {
                RiskBadge(risk: .orange)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .background(included ? Color.white.opacity(0.03) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
    }

    private var selectedLeftoverCount: Int {
        model.leftovers.filter { selectedLeftoverIDs.contains($0.id) }.count
    }

    private var selectedLeftoverBytes: Int64 {
        model.leftovers.filter { selectedLeftoverIDs.contains($0.id) }.reduce(0) { $0 + $1.totalBytes }
    }

    private func trashLeftovers() {
        let urls = model.leftovers
            .filter { selectedLeftoverIDs.contains($0.id) }
            .map { URL(fileURLWithPath: $0.libraryPath) }
        model.trashUserSelected(urls: urls)
        selectedLeftoverIDs.removeAll()
    }

    private func componentRow(_ component: AppComponent) -> some View {
        let included = includedComponents.contains(component.path)
        return HStack(spacing: 10) {
            Button {
                if included {
                    includedComponents.remove(component.path)
                } else {
                    includedComponents.insert(component.path)
                }
            } label: {
                Image(systemName: included ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(included ? Color.green : Color.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(component.kindDisplayName), \(component.bytes.bytesFormatted)")
            .accessibilityValue(included ? "included in removal" : "excluded from removal")

            VStack(alignment: .leading, spacing: 1) {
                Text(component.kindDisplayName).font(.callout.weight(.medium))
                Text(component.path).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(component.bytes.bytesFormatted).font(.callout.monospacedDigit())
            if component.kind == .bundle {
                RiskBadge(risk: .orange)
            } else if component.kind == .containers || component.kind == .groupContainers {
                RiskBadge(risk: .red)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .background(included ? Color.white.opacity(0.03) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
    }

    private var selectedComponentCount: Int {
        guard let app = selectedApp else { return 0 }
        return app.components.filter { includedComponents.contains($0.path) }.count
    }

    private var selectedComponentBytes: Int64 {
        guard let app = selectedApp else { return 0 }
        return app.components.filter { includedComponents.contains($0.path) }.reduce(0) { $0 + $1.bytes }
    }

    private func trashSelected() {
        guard let app = selectedApp else { return }
        let urls = app.components.filter { includedComponents.contains($0.path) }.map { URL(fileURLWithPath: $0.path) }
        model.trashUserSelected(urls: urls)
        includedComponents.removeAll()
    }
}

// MARK: - Developer Tools

struct DeveloperToolsScreen: View {
    @Environment(AppModel.self) private var model
    @State private var selectedIDs: Set<String> = []
    @State private var confirmTrash = false

    private var devCandidates: [CleanupCandidate] {
        model.candidates.filter { candidate in
            switch candidate.kind {
            case .derivedData, .deviceSupport, .simulatorCache, .packageCache, .archive:
                return true
            default:
                return false
            }
        }
    }

    private var devBytes: Int64 {
        model.scanResult?.categories[.developer] ?? 0
    }

    private var selectedURLs: [URL] {
        devCandidates.filter { selectedIDs.contains($0.id) }.map { $0.url }
    }

    var body: some View {
        Group {
            if model.scanResult == nil {
                ScanPromptView(
                    title: "Developer storage intelligence",
                    message: "Scan first, then Disk Robo breaks down Xcode DerivedData, simulator caches, device support, package caches, and more — each with build-impact explanations.",
                    onScan: { model.startFullScan() },
                    onQuickScan: { model.startQuickScan() }
                )
            } else {
                content
            }
        }
        .navigationTitle("Developer Tools")
        .alert("Move \(selectedURLs.count) item(s) to the Trash?", isPresented: $confirmTrash) {
            Button("Move to Trash", role: .destructive) {
                model.trashUserSelected(urls: selectedURLs)
                selectedIDs.removeAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Build artifacts are regenerated automatically, but the next build will be slower. Items remain recoverable in the Trash.")
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    DashboardCard(title: "Developer Storage",
                                  subtitle: "Everything classified as developer data in the last scan") {
                        Text(devBytes.bytesFormatted).font(.system(size: 28, weight: .bold, design: .rounded)).monospacedDigit()
                    }
                    .frame(width: 240)

                    DashboardCard(title: "Cleanable Build Artifacts",
                                  subtitle: "Green items regenerate automatically") {
                        Text(devCandidates.filter { $0.risk == .green }.reduce(0) { $0 + $1.sizeBytes }.bytesFormatted)
                            .font(.system(size: 28, weight: .bold, design: .rounded)).monospacedDigit()
                            .foregroundStyle(.green)
                        Text("\(devCandidates.count) candidates found").font(.caption).foregroundStyle(.secondary)
                    }
                }

                    DashboardCard(title: "Candidates",
                                  subtitle: "Select items to clean — every deletion is Trash-only and safety-verified") {
                    if devCandidates.isEmpty {
                        Text("No developer cleanup candidates found. Your build system is tidy.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        LazyVStack(spacing: 8) {
                            ForEach(devCandidates) { candidate in
                                CandidateRow(candidate: candidate,
                                             isExcluded: !selectedIDs.contains(candidate.id)) {
                                    if selectedIDs.contains(candidate.id) {
                                        selectedIDs.remove(candidate.id)
                                    } else {
                                        selectedIDs.insert(candidate.id)
                                    }
                                }
                            }
                        }
                        if !selectedIDs.isEmpty {
                            HStack {
                                Text("\(selectedIDs.count) selected").font(.callout.monospacedDigit())
                                Spacer()
                                Button("Move Selected to Trash…", role: .destructive) { confirmTrash = true }
                                    .buttonStyle(.borderedProminent).tint(.red)
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
    }
}

// MARK: - Browser Data

struct BrowserDataScreen: View {
    @Environment(AppModel.self) private var model
    @State private var selectedIDs: Set<String> = []
    @State private var confirmTrash = false

    private var browserCandidates: [CleanupCandidate] {
        model.candidates.filter { $0.category == .browser }
    }

    private var browserBytes: Int64 {
        model.scanResult?.categories[.browser] ?? 0
    }

    var body: some View {
        Group {
            if model.scanResult == nil {
                ScanPromptView(
                    title: "Browser storage",
                    message: "Scan first to see what Safari, Chrome, Firefox, and other browsers keep on disk — caches, site data, and profiles.",
                    onScan: { model.startFullScan() },
                    onQuickScan: { model.startQuickScan() }
                )
            } else {
                content
            }
        }
        .navigationTitle("Browser Data")
        .alert("Move \(selectedIDs.count) item(s) to the Trash?", isPresented: $confirmTrash) {
            Button("Move to Trash", role: .destructive) {
                let urls = browserCandidates.filter { selectedIDs.contains($0.id) }.map { $0.url }
                model.trashUserSelected(urls: urls)
                selectedIDs.removeAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Browsers rebuild caches automatically; you may be signed out of some sites or see slower first loads. Items remain recoverable in the Trash.")
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    DashboardCard(title: "Browser Data",
                                  subtitle: "Cache + website data classified as browser storage") {
                        Text(browserBytes.bytesFormatted).font(.system(size: 28, weight: .bold, design: .rounded)).monospacedDigit()
                    }
                    .frame(width: 240)
                }

                DashboardCard(title: "Browser Cleanup Candidates",
                              subtitle: "Cache locations browsers regenerate automatically") {
                    if browserCandidates.isEmpty {
                        Text("No accessible browser cache candidates found. Safari's data is protected by macOS privacy — grant Full Disk Access in Settings for complete coverage.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        LazyVStack(spacing: 8) {
                            ForEach(browserCandidates) { candidate in
                                CandidateRow(candidate: candidate,
                                             isExcluded: !selectedIDs.contains(candidate.id)) {
                                    if selectedIDs.contains(candidate.id) {
                                        selectedIDs.remove(candidate.id)
                                    } else {
                                        selectedIDs.insert(candidate.id)
                                    }
                                }
                            }
                        }
                        if !selectedIDs.isEmpty {
                            HStack {
                                Text("\(selectedIDs.count) selected").font(.callout.monospacedDigit())
                                Spacer()
                                Button("Move Selected to Trash…", role: .destructive) { confirmTrash = true }
                                    .buttonStyle(.borderedProminent).tint(.red)
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
    }
}

// MARK: - Exclusions

struct ExclusionsScreen: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                DashboardCard(title: "Exclusions",
                              subtitle: "Excluded folders are skipped by every scan, recommendation, and cleanup plan") {
                    let exclusions = model.settings.settings.excludedPaths
                    if exclusions.isEmpty {
                        Text("No exclusions yet. Add folders you never want Disk Robo to touch or analyze (for example, a VM images folder you manage yourself).")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        VStack(spacing: 8) {
                            ForEach(Array(exclusions.enumerated()), id: \.offset) { index, path in
                                HStack(spacing: 9) {
                                    Image(systemName: "folder.badge.minus").foregroundStyle(.secondary)
                                    Text(path).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    Button {
                                        model.removeExclusion(at: index)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Remove exclusion \(path)")
                                }
                                .padding(9)
                                .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }
                    Button("Add Exclusion…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.message = "Choose a folder to exclude from all Disk Robo scans"
                        if panel.runModal() == .OK, let url = panel.url {
                            model.addExclusion(url)
                        }
                    }
                    .controlSize(.small)
                    .padding(.top, 4)
                }
            }
            .padding(20)
        }
        .navigationTitle("Exclusions")
    }
}
