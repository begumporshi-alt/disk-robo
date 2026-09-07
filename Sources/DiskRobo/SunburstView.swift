import SwiftUI
import RoboCore

// MARK: - Sunburst geometry

/// One drawable slice of the sunburst (a ring segment bound to a tree node).
struct SunburstSegment: Identifiable {
    let node: StorageNode
    let startDeg: Double   // 0 = top, increasing clockwise
    let endDeg: Double
    let ring: Int          // 1 = category ring, 2 = detail ring
    let color: Color

    var id: String { "\(ring)-\(node.id.uuidString)" }
    var spanDeg: Double { endDeg - startDeg }
}

enum SunburstGeometry {
    /// Moat between the hub and ring 1, and between ring 1 and ring 2.
    static let hubGap: CGFloat = 4
    static let ringGap: CGFloat = 2.5

    /// Convert a polar coordinate (screen point) to degrees-from-top-clockwise.
    static func degrees(from point: CGPoint, center: CGPoint) -> Double {
        let dx = Double(point.x - center.x)
        let dy = Double(point.y - center.y)
        var deg = atan2(dy, dx) * 180 / .pi + 90
        if deg < 0 { deg += 360 }
        return deg
    }

    static func radius(from point: CGPoint, center: CGPoint) -> CGFloat {
        hypot(point.x - center.x, point.y - center.y)
    }

    /// Annulus wedge path. Input angles are degrees-from-top-clockwise.
    static func wedgePath(center: CGPoint, innerR: CGFloat, outerR: CGFloat,
                          startDeg: Double, endDeg: Double) -> Path {
        var p = Path()
        p.addArc(center: center, radius: outerR,
                 startAngle: .degrees(startDeg - 90), endAngle: .degrees(endDeg - 90), clockwise: true)
        p.addLine(to: CGPoint(x: center.x + innerR * cos(CGFloat((endDeg - 90) * .pi / 180)),
                              y: center.y + innerR * sin(CGFloat((endDeg - 90) * .pi / 180))))
        p.addArc(center: center, radius: innerR,
                 startAngle: .degrees(endDeg - 90), endAngle: .degrees(startDeg - 90), clockwise: false)
        p.closeSubpath()
        return p
    }

    /// Inner/outer radius of a ring, as absolute radii for a given sunburst radius.
    static func ringRadii(ring: Int, outerR: CGFloat) -> (inner: CGFloat, outer: CGFloat) {
        switch ring {
        case 1: return (outerR * 0.34, outerR * 0.655)
        default: return (outerR * 0.655 + ringGap, outerR)
        }
    }

    /// Wedge path for a segment, optionally expanded outward (hover pop-out).
    static func wedgePath(_ segment: SunburstSegment, center: CGPoint, outerR: CGFloat,
                          expand: CGFloat = 0) -> Path {
        let r = ringRadii(ring: segment.ring, outerR: outerR)
        return wedgePath(center: center,
                         innerR: max(0, r.inner - expand),
                         outerR: r.outer + expand,
                         startDeg: segment.startDeg, endDeg: segment.endDeg)
    }

    /// Radial gradient endpoints for a segment (inner edge → outer edge through
    /// the segment's mid-angle).
    static func gradientEndpoints(_ segment: SunburstSegment, center: CGPoint,
                                  outerR: CGFloat, expand: CGFloat = 0) -> (start: CGPoint, end: CGPoint) {
        let r = ringRadii(ring: segment.ring, outerR: outerR)
        let rad = CGFloat((segment.startDeg + segment.endDeg) / 2 - 90) * .pi / 180
        let c = CGFloat(cos(rad)), s = CGFloat(sin(rad))
        return (CGPoint(x: center.x + (r.inner - expand) * c, y: center.y + (r.inner - expand) * s),
                CGPoint(x: center.x + (r.outer + expand) * c, y: center.y + (r.outer + expand) * s))
    }

    /// Build both rings for a node's children (and grandchildren), capped for legibility.
    static func segments(for node: StorageNode, in size: CGSize) -> [SunburstSegment] {
        let outerR = min(size.width, size.height) / 2 - 6
        guard outerR > 40, node.size > 0, !node.children.isEmpty else { return [] }

        let gap: Double = 0.7
        let childGap: Double = 0.35
        let visibleChildren = node.children.filter { $0.size > 0 }
        let total = visibleChildren.reduce(0.0) { $0 + Double($1.size) }
        guard total > 0 else { return [] }

        var result: [SunburstSegment] = []
        var cursor = 0.0
        for child in visibleChildren {
            let span = Double(child.size) / total * 360
            let color = Theme.color(for: child.category)
            result.append(SunburstSegment(node: child, startDeg: cursor + gap / 2,
                                          endDeg: cursor + span - gap / 2, ring: 1, color: color))
            // Ring 2: grandchildren within this slice
            if span > 3 {
                result.append(contentsOf: grandchildSegments(parent: child, span: span,
                                                             startCursor: cursor, gap: childGap))
            }
            cursor += span
        }
        return result
    }

    private static func grandchildSegments(parent: StorageNode, span: Double,
                                           startCursor: Double, gap: Double) -> [SunburstSegment] {
        // lazy before prefix: only walks children until 14 matches are found,
        // instead of filtering the parent's ENTIRE child list (O(n) per ring-1
        // segment — visible as map-load lag on wide directories).
        let grandkids = Array(parent.children.lazy.filter { $0.size > 0 }.prefix(14))
        let grandTotal = grandkids.reduce(0.0) { $0 + Double($1.size) }
        guard grandTotal > 0 else { return [] }

        // Full parent-category color; ring-2 dimming happens at draw time so
        // tooltips can show the undimmed dot.
        let color = Theme.color(for: parent.category)
        var out: [SunburstSegment] = []
        var gCursor = startCursor
        for grand in grandkids {
            let gSpan = Double(grand.size) / grandTotal * span
            if gSpan > 0.25 {
                out.append(SunburstSegment(node: grand, startDeg: gCursor + gap / 2,
                                           endDeg: gCursor + gSpan - gap / 2, ring: 2, color: color))
            }
            gCursor += gSpan
        }
        return out
    }
}

// MARK: - Sunburst canvas

struct SunburstView: View {
    let node: StorageNode
    /// Parent folder name when drilled below the root — shows a "go up" pill
    /// in the hub; nil at the scan root.
    var upToName: String? = nil
    var onUp: () -> Void = {}
    @Binding var hovered: SunburstSegment?
    var onDrill: (StorageNode) -> Void

    /// PF-4: geometry is cached per (node, size). It used to be rebuilt on
    /// every mouse-move (hit-testing AND Canvas redraw re-ran the full
    /// segment construction — thousands of Path allocations per hover event).
    @State private var cachedSegments: [SunburstSegment] = []
    @State private var currentSize: CGSize = .zero
    @State private var pointingCursor = false

    var body: some View {
        ZStack {
            // Base layer: depends only on (node, size) — hover changes do NOT
            // re-render it.
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let outerR = min(size.width, size.height) / 2 - 6
                guard outerR > 40 else { return }

                // Center hub disk, inset from ring 1 — a quiet moat separates them.
                let hubR = hubRadius(outerR: outerR)
                let hubRect = CGRect(x: center.x - hubR, y: center.y - hubR,
                                     width: hubR * 2, height: hubR * 2)
                context.fill(Path(ellipseIn: hubRect),
                             with: .radialGradient(Gradient(colors: [Theme.cardFill.opacity(0.85),
                                                                      Theme.cardFill]),
                                                   center: CGPoint(x: center.x, y: center.y - hubR * 0.45),
                                                   startRadius: 0, endRadius: hubR * 1.35))
                context.stroke(Path(ellipseIn: hubRect), with: .color(Theme.cardStroke), lineWidth: 1)

                for segment in cachedSegments {
                    let path = SunburstGeometry.wedgePath(segment, center: center, outerR: outerR)
                    let (start, end) = SunburstGeometry.gradientEndpoints(segment, center: center, outerR: outerR)
                    context.fill(path, with: .linearGradient(
                        Gradient(colors: radialColors(segment, bright: false)),
                        startPoint: start, endPoint: end))
                    context.stroke(path, with: .color(Theme.appBackground.opacity(0.9)),
                                   lineWidth: segment.ring == 1 ? 1 : 0.75)
                }
            }
            // Hover layer: redraws exactly one wedge, popped outward with a glow.
            .allowsHitTesting(false)

            Canvas { context, size in
                guard let hovered else { return }
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let outerR = min(size.width, size.height) / 2 - 6
                let path = SunburstGeometry.wedgePath(hovered, center: center, outerR: outerR, expand: 3)
                let (start, end) = SunburstGeometry.gradientEndpoints(hovered, center: center,
                                                                      outerR: outerR, expand: 3)
                // Soft halo behind the popped wedge (no shadow API in Canvas).
                context.stroke(path, with: .color(hovered.color.opacity(0.45)), lineWidth: 5)
                context.fill(path, with: .linearGradient(
                    Gradient(colors: radialColors(hovered, bright: true)),
                    startPoint: start, endPoint: end))
                context.stroke(path, with: .color(Color.white.opacity(0.4)), lineWidth: 1)
            }
            .allowsHitTesting(false)

            centerHub
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onEnded { value in
                    if let hit = segment(at: value.location) {
                        onDrill(hit.node)
                    }
                }
        )
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                let hit = segment(at: location)
                hovered = hit
                setPointingCursor(hit != nil || overHub(location))
            case .ended:
                hovered = nil
                setPointingCursor(false)
            }
        }
        .background(GeometryReader { geo in
            Color.clear.onAppear { sizeChanged(geo.size) }
                .onChange(of: geo.size) { _, new in sizeChanged(new) }
        })
        .onChange(of: node.id) { _, _ in rebuildCache() }
        .onDisappear { setPointingCursor(false) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sunburst map of \(node.name), \(node.size.bytesFormatted)")
    }

    // MARK: Hub (center label + go-up control)

    private func hubRadius(outerR: CGFloat) -> CGFloat {
        outerR * 0.34 - SunburstGeometry.hubGap
    }

    private func hubRadius(in size: CGSize) -> CGFloat {
        let outerR = min(size.width, size.height) / 2 - 6
        guard outerR > 40 else { return 0 }
        return hubRadius(outerR: outerR)
    }

    private var centerHub: some View {
        let canGoUp = upToName != nil
        let hubWidth = max(120, hubRadius(in: currentSize) * 2 - 12)
        let content = VStack(spacing: 3) {
            if let upToName {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.up").font(.system(size: 8, weight: .bold))
                    Text(upToName).font(.caption2.weight(.medium)).lineLimit(1)
                }
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Color.white.opacity(0.07), in: Capsule())
                .foregroundStyle(.secondary)
            }
            Text(node.size.bytesFormatted)
                .font(.system(.title3, design: .rounded).weight(.bold))
                .monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.6)
            if !canGoUp {
                Text("Used").font(.caption2).foregroundStyle(.secondary)
            }
            Text(node.name)
                .font(.caption2).foregroundStyle(.tertiary)
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: hubWidth)
        .multilineTextAlignment(.center)

        return Group {
            if canGoUp {
                content
                    .contentShape(Rectangle())
                    .onTapGesture { onUp() }
            } else {
                content
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Current folder \(node.name), \(node.size.bytesFormatted)")
        .accessibilityHint(canGoUp ? "Click to go up one level" : "")
    }

    private func overHub(_ point: CGPoint) -> Bool {
        guard upToName != nil, currentSize.width > 0 else { return false }
        let center = CGPoint(x: currentSize.width / 2, y: currentSize.height / 2)
        return SunburstGeometry.radius(from: point, center: center) <= hubRadius(in: currentSize)
    }

    // MARK: Drawing helpers

    /// Inner→outer gradient stops per ring: lighter at the inner edge, full
    /// color at the rim; hovered wedges brighten further.
    private func radialColors(_ segment: SunburstSegment, bright: Bool) -> [Color] {
        let c = segment.color
        if segment.ring == 1 {
            return bright ? [c.opacity(0.85), c] : [c.opacity(0.55), c]
        }
        return bright ? [c.opacity(0.44), c.opacity(0.7)] : [c.opacity(0.24), c.opacity(0.5)]
    }

    private func setPointingCursor(_ pointing: Bool) {
        guard pointing != pointingCursor else { return }
        pointingCursor = pointing
        if pointing {
            NSCursor.pointingHand.push()
        } else {
            NSCursor.pop()
        }
    }

    // MARK: Cache + hit-testing

    private func sizeChanged(_ newSize: CGSize) {
        currentSize = newSize
        rebuildCache()
    }

    private func rebuildCache() {
        cachedSegments = SunburstGeometry.segments(for: node, in: currentSize)
    }

    /// Hit-tests against the cached segment list — O(n) per hover event, no
    /// geometry rebuild.
    private func segment(at point: CGPoint) -> SunburstSegment? {
        guard currentSize.width > 0 else { return nil }
        let center = CGPoint(x: currentSize.width / 2, y: currentSize.height / 2)
        let outerR = min(currentSize.width, currentSize.height) / 2 - 6
        let r = SunburstGeometry.radius(from: point, center: center)
        guard r <= outerR, r >= outerR * 0.34 else { return nil }
        let deg = SunburstGeometry.degrees(from: point, center: center)
        return cachedSegments.first { $0.startDeg <= deg && deg <= $0.endDeg }
    }
}

// MARK: - Tooltip card (hovered segment breakdown)

struct SunburstTooltip: View {
    let segment: SunburstSegment
    let parent: StorageNode?
    var onReveal: (URL) -> Void
    var onOpen: (StorageNode) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle().fill(segment.color).frame(width: 9, height: 9)
                Text(segment.node.name).font(.callout.weight(.semibold)).lineLimit(1)
                Spacer()
                Text(segment.node.size.bytesFormatted).font(.callout.monospacedDigit().weight(.semibold))
            }
            HStack(spacing: 6) {
                Text(segment.node.category.displayName)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 1.5)
                    .background(segment.color.opacity(0.16), in: Capsule())
                    .foregroundStyle(segment.color)
                if segment.node.size > 0, let parent, parent.size > 0 {
                    Text(Format.percent(Double(segment.node.size) / Double(parent.size)) + " of " + parent.name)
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            Divider()
            let children = segment.node.children.sorted { $0.size > $1.size }
            if children.isEmpty {
                Text("Leaf item — nothing inside.").font(.caption).foregroundStyle(.secondary)
            } else {
                let top = children.prefix(5)
                let known = top.reduce(0) { $0 + $1.size }
                let others = segment.node.size - known
                ForEach(Array(top.enumerated()), id: \.element.id) { _, child in
                    HStack {
                        Text(child.name).font(.caption).lineLimit(1)
                        Spacer()
                        Text(child.size.bytesFormatted).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                if others > 0 {
                    HStack {
                        Text("Others").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(others.bytesFormatted).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
            Divider()
            HStack {
                Button {
                    onReveal(segment.node.url)
                } label: {
                    Label("Reveal in Finder", systemImage: "arrow.up.right.square").font(.caption)
                }
                .buttonStyle(.link)
                if !segment.node.children.isEmpty {
                    Spacer()
                    Button {
                        onOpen(segment.node)
                    } label: {
                        Label("Drill In", systemImage: "arrow.down.right.square").font(.caption)
                    }
                    .buttonStyle(.link)
                }
            }
        }
        .padding(12)
        .frame(width: 240)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.cardStroke))
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
    }
}

// MARK: - Breadcrumbs

struct MapBreadcrumbs: View {
    let root: StorageNode
    let path: [StorageNode]
    let onJump: (Int) -> Void   // 0 = root, i = path[i-1]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                breadcrumbChip(icon: "internaldrive.fill", name: root.name, active: path.isEmpty) { onJump(0) }
                ForEach(Array(path.enumerated()), id: \.element.id) { index, node in
                    Image(systemName: "chevron.right").font(.system(size: 8)).foregroundStyle(.tertiary)
                    breadcrumbChip(icon: "folder.fill", name: node.name, active: index == path.count - 1) {
                        onJump(index + 1)
                    }
                }
            }
            .padding(.horizontal, 4)
        }
    }

    private func breadcrumbChip(icon: String, name: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 9))
                Text(name).font(.caption).lineLimit(1)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(active ? Color.accentColor.opacity(0.18) : Color.white.opacity(0.04), in: Capsule())
            .foregroundStyle(active ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Storage Map card (sunburst + breadcrumbs + tooltip)
/// Reused on the Overview dashboard (compact) and the Storage Map screen (large).

struct StorageMapCard: View {
    @Environment(AppModel.self) private var model
    @State private var hoveredSegment: SunburstSegment?

    var body: some View {
        Group {
            if let root = model.mapRoot {
                cardBody(root: root)
            } else if model.restoring {
                DashboardCard(title: "Storage Map", subtitle: "Visualize what's taking space on your disk") {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Restoring your last scan…")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                }
            } else {
                DashboardCard(title: "Storage Map", subtitle: "Visualize what's taking space on your disk") {
                    ScanPromptView(
                        title: "No map yet",
                        message: "Scan your home folder to explore an interactive map of where every gigabyte lives.",
                        actionTitle: "Scan Home",
                        quickActionTitle: "Quick Scan",
                        onScan: { model.startFullScan() },
                        onQuickScan: { model.startQuickScan() }
                    )
                    .padding(.vertical, 8)
                }
            }
        }
    }

    @ViewBuilder
    private func cardBody(root: StorageNode) -> some View {
        DashboardCard(
            title: "Storage Map",
            subtitle: "Visualize what's taking space on your disk"
        ) {
            VStack(spacing: 10) {
                ZStack(alignment: .topTrailing) {
                    mapArea
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 360)

                    if let hovered = hoveredSegment {
                        SunburstTooltip(
                            segment: hovered,
                            parent: model.mapParent(of: hovered.node),
                            onReveal: { url in NSWorkspace.shared.activateFileViewerSelecting([url]) },
                            onOpen: { model.drillMap(into: $0) }
                        )
                        .padding(8)
                        .transition(.opacity)
                    }
                }
                MapBreadcrumbs(root: root, path: model.mapPath) { depth in
                    model.jumpMap(toDepth: depth)
                }
            }
        }
        .animation(.easeInOut(duration: 0.15), value: hoveredSegment?.id)
        .animation(.easeOut(duration: 0.22), value: model.mapCurrent?.id)
    }

    @ViewBuilder
    private var mapArea: some View {
        if let current = model.mapCurrent {
            ZStack {
                SunburstView(
                    node: current,
                    upToName: model.mapParent(of: current)?.name,
                    onUp: { model.jumpMap(toDepth: model.mapPath.count - 1) },
                    hovered: $hoveredSegment
                ) { model.drillMap(into: $0) }
                ringLabels(current)
                    .allowsHitTesting(false)
            }
            .id(current.id)
            .transition(.scale(scale: 0.97).combined(with: .opacity))
        }
    }

    /// Labels drawn on the inner ring for wide-enough segments. One pass with
    /// a running cursor (the old per-label angleCursor was O(n²)).
    @ViewBuilder
    private func ringLabels(_ current: StorageNode) -> some View {
        GeometryReader { geo in
            let labels = ringLabelInfos(current, size: geo.size)
            ForEach(labels, id: \.id) { info in
                VStack(spacing: 1) {
                    Text(info.name).font(.system(size: 10.5, weight: .semibold))
                    Text(info.sizeText).font(.system(size: 10)).monospacedDigit()
                    Text(info.percent).font(.system(size: 9)).monospacedDigit().opacity(0.85)
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.55), radius: 2, y: 1)
                .position(info.point)
            }
        }
    }

    private func ringLabelInfos(_ current: StorageNode, size: CGSize) -> [LabelInfo] {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let outerR = min(size.width, size.height) / 2 - 6
        let labelR = (outerR * 0.34 + outerR * 0.655) / 2
        let visible = current.children.filter { $0.size > 0 }
        let total = visible.reduce(0.0) { $0 + Double($1.size) }
        guard total > 0 else { return [] }

        var labels: [LabelInfo] = []
        var cursor = 0.0
        for child in visible {
            let span = Double(child.size) / total * 360
            defer { cursor += span }
            guard span > 16 else { continue }
            let mid = cursor + span / 2
            let rad = (CGFloat(mid) - 90) * .pi / 180
            labels.append(LabelInfo(
                id: child.id,
                point: CGPoint(x: center.x + labelR * cos(rad), y: center.y + labelR * sin(rad)),
                name: child.name,
                sizeText: child.size.bytesFormatted,
                percent: Format.percent(Double(child.size) / total),
                dark: span > 26
            ))
        }
        return labels
    }

    private struct LabelInfo: Identifiable {
        let id: UUID
        let point: CGPoint
        let name: String
        let sizeText: String
        let percent: String
        let dark: Bool
    }
}
