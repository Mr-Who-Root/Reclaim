import SwiftUI
import Charts

/// Mac Overview: free space, the free-space trend, Smart Scan across every tool, and a card per tool.
struct HomeView: View {
    private var app: AppModel { AppModel.shared }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HomeHero()
                HStack(alignment: .top, spacing: 16) {
                    FreeSpaceTrend()
                    CleanedCard()
                        .frame(width: 300)
                }
                if app.hasSessionResults {
                    SmartScanResults()
                }
                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle(title: "Tools", subtitle: "Look first, decide yourself, then reclaim. Every tool is unlocked.")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 12)], spacing: 12) {
                        ForEach(Route.allCases.filter { $0 != .home && $0 != .settings }) { route in
                            ToolCard(route: route)
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 1120)
            .frame(maxWidth: .infinity)
        }
        .onAppear { app.refreshVolume() }
    }
}

// MARK: - Hero

private struct HomeHero: View {
    @Environment(\.theme) private var theme
    private var app: AppModel { AppModel.shared }

    private var greeting: LocalizedStringKey {
        switch Calendar.current.component(.hour, from: .now) {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        default: return "Good evening"
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 28) {
            DiskDonut(volume: app.volume)
                .frame(width: 168, height: 168)

            VStack(alignment: .leading, spacing: 10) {
                Text(greeting).font(.title3).foregroundStyle(.secondary)
                Text(Fmt.bytes(app.volume.free))
                    .font(.system(size: 46, weight: .bold, design: .rounded)).monospacedDigit()
                    .contentTransition(.numericText())
                Text("free of \(Fmt.bytes(app.volume.total)) on Macintosh HD").font(.callout).foregroundStyle(.secondary)
                HStack(spacing: 18) {
                    LegendDot(color: theme.accentColor, title: "Used", value: Fmt.bytes(app.volume.used))
                    LegendDot(color: .white.opacity(theme.isVivid && theme.dark ? 0.35 : 0.9), outlined: !(theme.isVivid && theme.dark),
                              title: "Free", value: Fmt.bytes(app.volume.free))
                }
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 12) {
                Label("Smart Scan", systemImage: "sparkle.magnifyingglass").font(.headline)
                Text("One read-only pass across every section: cleanup tools, your apps, Security Check, the Storage Map and the Trash. Nothing moves until you approve it.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if app.smartScanRunning {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(app.scheduledScanRunning ? "Scheduled scan running…" : "Scanning your Mac…").font(.callout)
                        Spacer()
                        Button("Stop") { app.cancelSmartScan() }.buttonStyle(.softGlass)
                    }
                } else {
                    Button {
                        AccessCenter.shared.ensureAccess { app.startSmartScan() }
                    } label: {
                        Label(!AccessCenter.shared.homeGranted ? "Grant Access & Scan" : (app.hasSessionResults ? "Scan Again" : "Run Smart Scan"),
                              systemImage: "sparkle.magnifyingglass")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.pillLarge)
                }
                if let last = app.lastSmartScan {
                    Text("Last Smart Scan \(Fmt.relative(last))").font(.caption).foregroundStyle(.secondary)
                } else if !AccessCenter.shared.homeGranted {
                    Text("Reclaim asks for your Home folder (\(FS.home.path)) once, then checks every location before scanning.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(width: 290)
        }
        .card(padding: 22)
    }
}

/// Two-segment used/free ring with the used share in the middle.
private struct DiskDonut: View {
    let volume: VolumeStats
    @Environment(\.theme) private var theme

    private struct Slice: Identifiable { let id: String; let bytes: Int64; let color: Color }

    var body: some View {
        let slices = [
            Slice(id: "used", bytes: volume.used, color: theme.accentColor.mix(with: .white, by: theme.dark ? 0.15 : 0)),
            Slice(id: "free", bytes: volume.free, color: theme.isVivid && theme.dark ? .white.opacity(0.22) : Color.secondary.opacity(0.22)),
        ]
        ZStack {
            Chart(slices) { s in
                SectorMark(angle: .value("Bytes", s.bytes), innerRadius: .ratio(0.74), angularInset: 1.2)
                    .cornerRadius(4)
                    .foregroundStyle(s.color)
            }
            .chartLegend(.hidden)
            VStack(spacing: 0) {
                Text(Fmt.percent(volume.usedFraction)).font(.system(size: 30, weight: .bold, design: .rounded)).monospacedDigit()
                Text("used").font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Disk usage")
        .accessibilityValue("\(Fmt.percent(volume.usedFraction)) used, \(Fmt.bytes(volume.free)) free")
    }
}

private struct LegendDot: View {
    let color: Color
    var outlined = false
    let title: LocalizedStringKey
    let value: String

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 9, height: 9)
                .overlay(Circle().strokeBorder(Color.secondary.opacity(outlined ? 0.6 : 0)))
            Text(title).foregroundStyle(.secondary)
            Text(value).fontWeight(.semibold).monospacedDigit()
        }
        .font(.callout)
    }
}

// MARK: - Free space trend

private struct FreeSpaceTrend: View {
    @Environment(\.theme) private var theme
    @State private var hovered: Date?
    private var history: SpaceHistory { SpaceHistory.shared }

    var body: some View {
        let points = history.daily(days: 30)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Free space, last 30 days").font(.headline)
                Spacer()
                if let change = change(points) {
                    Text(change).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
            if points.count < 2 {
                VStack(spacing: 8) {
                    Image(systemName: "chart.xyaxis.line").font(.title).foregroundStyle(.secondary)
                    Text("Reclaim records your free space each day it runs. Your trend appears here from tomorrow.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, minHeight: 150)
            } else {
                chart(points).frame(height: 150)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 18)
    }

    private func gb(_ bytes: Int64) -> Double { Double(bytes) / 1_000_000_000 }

    private func chart(_ points: [SpaceHistory.Sample]) -> some View {
        let lineColor = theme.isVivid && theme.dark ? Color.white : theme.accentColor
        let selected = hovered.flatMap { h in points.min { abs($0.date.timeIntervalSince(h)) < abs($1.date.timeIntervalSince(h)) } }
        return Chart {
            ForEach(points) { p in
                AreaMark(x: .value("Day", p.date, unit: .day), y: .value("Free", gb(p.free)))
                    .foregroundStyle(LinearGradient(colors: [lineColor.opacity(0.35), lineColor.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Day", p.date, unit: .day), y: .value("Free", gb(p.free)))
                    .foregroundStyle(lineColor)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                    .interpolationMethod(.monotone)
            }
            if let selected {
                RuleMark(x: .value("Day", selected.date, unit: .day))
                    .foregroundStyle(Color.secondary.opacity(0.5))
                PointMark(x: .value("Day", selected.date, unit: .day), y: .value("Free", gb(selected.free)))
                    .symbolSize(70)
                    .foregroundStyle(lineColor)
                    .annotation(position: .top, spacing: 6, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        VStack(spacing: 1) {
                            Text(Fmt.bytes(selected.free)).font(.caption.weight(.semibold)).monospacedDigit()
                            Text(selected.date.formatted(date: .abbreviated, time: .omitted)).font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                    }
            }
        }
        .chartXSelection(value: $hovered)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.18))
                AxisValueLabel { if let v = value.as(Double.self) { Text("\(Int(v)) GB") } }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
            }
        }
        .chartYScale(domain: .automatic(includesZero: false))
        .accessibilityLabel("Free space over the last 30 days")
    }

    private func change(_ points: [SpaceHistory.Sample]) -> String? {
        guard let first = points.first, let last = points.last, points.count >= 2 else { return nil }
        let delta = last.free - first.free
        let since = first.date.formatted(date: .abbreviated, time: .omitted)
        return delta >= 0
            ? String(localized: "+\(Fmt.bytes(delta)) since \(since)")
            : String(localized: "−\(Fmt.bytes(-delta)) since \(since)")
    }
}

// MARK: - Cleaned card

private struct CleanedCard: View {
    private var app: AppModel { AppModel.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Cleaned up with Reclaim", systemImage: "leaf.fill").font(.headline)
            Text(Fmt.bytes(app.trashLog.totalReclaimed))
                .font(.system(size: 34, weight: .bold, design: .rounded)).monospacedDigit()
                .foregroundStyle(.tint)
            Text(app.trashLog.totalReclaimed > 0
                 ? "Moved to the Trash so far. Empty the Trash to free it for good."
                 : "Everything Reclaim removes goes to the Trash first, so you can always change your mind.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            HStack {
                Button("Review Trash") { app.route = .trash }.buttonStyle(.softGlass)
                Button("Guided Cleanup") { app.route = .guided }.buttonStyle(.softGlass)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 180, alignment: .topLeading)
        .card(padding: 18)
    }
}

// MARK: - Smart Scan results

private struct SmartScanResults: View {
    private var app: AppModel { AppModel.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                SectionTitle(title: app.smartScanRunning ? "Scanning…" : "Found to review",
                             subtitle: app.smartScanRunning ? "Results appear as each tool finishes." : "Nothing has been removed. Open a tool to review its results.")
                Spacer()
                if !app.smartScanRunning {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(Fmt.bytes(app.totalReclaimable)).font(.system(.title, design: .rounded).weight(.bold)).monospacedDigit().foregroundStyle(.tint)
                        if app.trashStatus.waitingBytes > 0 {
                            Text("+ \(Fmt.bytes(app.trashStatus.waitingBytes)) already in the Trash").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            VStack(spacing: 0) {
                ForEach(app.scanTools, id: \.route) { tool in
                    SmartScanRow(tool: tool)
                    Divider().padding(.leading, 44).opacity(0.5)
                }
                AppsReportRow()
                Divider().padding(.leading, 44).opacity(0.5)
                SecurityRow()
                Divider().padding(.leading, 44).opacity(0.5)
                StorageMapReportRow()
                Divider().padding(.leading, 44).opacity(0.5)
                TrashReportRow()
            }
            .card(padding: 6)
            if !app.smartScanRunning, app.totalReclaimable > 0 {
                HStack {
                    Image(systemName: "checklist").foregroundStyle(.tint)
                    Text("Want help deciding? Guided Cleanup turns these results into a short plan you approve item by item.")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Open Guided Cleanup") { app.route = .guided }.buttonStyle(.pill)
                }
            }
        }
    }
}

private struct SmartScanRow: View {
    let tool: any ScanTool
    private var app: AppModel { AppModel.shared }

    var body: some View {
        Button {
            app.route = tool.route
        } label: {
            HStack(spacing: 12) {
                RouteIcon(route: tool.route, side: 26)
                Text(tool.route.title)
                Spacer()
                status
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var status: some View {
        switch tool.phase {
        case .scanning(let message):
            HStack(spacing: 6) {
                Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).frame(maxWidth: 260, alignment: .trailing)
                ProgressView().controlSize(.small)
            }
        case .done:
            if tool.reclaimableBytes > 0 {
                Text("\(Fmt.count(tool.itemCount, "item")) · \(Text(Fmt.bytes(tool.reclaimableBytes)).fontWeight(.semibold).foregroundStyle(.primary))")
                    .foregroundStyle(.secondary)
            } else {
                Label("All clear", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption).lineLimit(1)
        case .idle:
            Text("Not scanned yet").foregroundStyle(.tertiary).font(.caption)
        }
    }
}

private struct SecurityRow: View {
    private var app: AppModel { AppModel.shared }

    var body: some View {
        Button {
            app.route = .security
        } label: {
            HStack(spacing: 12) {
                RouteIcon(route: .security, side: 26)
                Text("Security Check")
                Spacer()
                switch app.security.phase {
                case .scanning:
                    ProgressView().controlSize(.small)
                case .done:
                    if app.security.attentionCount > 0 {
                        Label("\(Fmt.count(app.security.attentionCount, "item")) worth a look", systemImage: "exclamationmark.shield")
                            .foregroundStyle(.orange).font(.callout)
                    } else {
                        Label("Nothing needs attention", systemImage: "checkmark.shield.fill").foregroundStyle(.green).font(.callout)
                    }
                default:
                    Text("Read-only").foregroundStyle(.tertiary).font(.caption)
                }
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// One read-only line in the Smart Scan report.
private struct ReportRow<Status: View>: View {
    let route: Route
    @ViewBuilder var status: () -> Status
    private var app: AppModel { AppModel.shared }

    var body: some View {
        Button {
            app.route = route
        } label: {
            HStack(spacing: 12) {
                RouteIcon(route: route, side: 26)
                Text(route.title)
                Spacer()
                status()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct AppsReportRow: View {
    private var model: AppsModel { AppModel.shared.apps }
    var body: some View {
        ReportRow(route: .apps) {
            if model.appsLoading {
                ProgressView().controlSize(.small)
            } else if model.apps.isEmpty {
                Text("Not scanned yet").foregroundStyle(.tertiary).font(.caption)
            } else {
                Text("\(Fmt.count(model.apps.count, "app")) installed · \(Text(Fmt.bytes(model.installedAppsBytes)).fontWeight(.semibold).foregroundStyle(.primary))")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct StorageMapReportRow: View {
    private var model: StorageMapModel { AppModel.shared.storageMap }
    var body: some View {
        ReportRow(route: .map) {
            switch model.phase {
            case .scanning(let message):
                HStack(spacing: 6) {
                    Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).frame(maxWidth: 260, alignment: .trailing)
                    ProgressView().controlSize(.small)
                }
            case .done:
                if let root = model.root {
                    let top = root.children.sorted { $0.size > $1.size }.prefix(2)
                        .map { "\($0.url.lastPathComponent) \(Fmt.bytes($0.size))" }.joined(separator: ", ")
                    Text("\(Fmt.bytes(root.size)) mapped · biggest: \(top)")
                        .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption).lineLimit(1)
            case .idle:
                Text("Not scanned yet").foregroundStyle(.tertiary).font(.caption)
            }
        }
    }
}

private struct TrashReportRow: View {
    private var status: TrashStatus { AppModel.shared.trashStatus }
    var body: some View {
        ReportRow(route: .trash) {
            switch status.phase {
            case .scanning:
                ProgressView().controlSize(.small)
            case .done:
                if let total = status.totalBytes {
                    if total > 0 {
                        Text("\(Fmt.count(status.itemCount ?? 0, "item")) · \(Text(Fmt.bytes(total)).fontWeight(.semibold).foregroundStyle(.primary)) waiting to be emptied")
                            .foregroundStyle(.secondary)
                    } else {
                        Label("Empty", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
                    }
                } else {
                    Text("Full Disk Access needed to measure").font(.caption).foregroundStyle(.secondary)
                }
            default:
                Text("Not scanned yet").foregroundStyle(.tertiary).font(.caption)
            }
        }
    }
}

// MARK: - Tool cards

private struct ToolCard: View {
    let route: Route
    @State private var hovering = false
    @Environment(\.theme) private var theme
    private var app: AppModel { AppModel.shared }

    var body: some View {
        Button {
            app.route = route
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    RouteIcon(route: route, side: 36)
                    Spacer()
                    statusBadge
                }
                Text(route.title).font(.system(.headline, design: .rounded))
                Text(route.tagline).font(.caption).foregroundStyle(.secondary).lineLimit(2, reservesSpace: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card(padding: 14)
            .overlay(RoundedRectangle(cornerRadius: theme.isVivid ? 16 : 12, style: .continuous)
                .strokeBorder(route.color.opacity(hovering ? 0.8 : 0), lineWidth: 1.5))
            .shadow(color: route.color.opacity(hovering ? 0.3 : 0), radius: 12, y: 4)
            .scaleEffect(hovering ? 1.015 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .accessibilityHint("Opens \(route.title)")
    }

    @ViewBuilder private var statusBadge: some View {
        if let tool = app.tool(for: route) {
            if tool.phase.isScanning {
                ProgressView().controlSize(.small)
            } else if tool.phase.isDone {
                if tool.reclaimableBytes > 0 { Badge(text: Fmt.bytes(tool.reclaimableBytes), color: route.color) }
                else { Badge(text: String(localized: "All clear"), color: .green) }
            }
        } else if route == .security, app.security.phase.isDone {
            if app.security.attentionCount > 0 { Badge(text: String(localized: "\(app.security.attentionCount) to review"), color: .orange) }
            else { Badge(text: String(localized: "Healthy"), color: .green) }
        } else if route == .trash, app.trashLog.totalReclaimed > 0 {
            Badge(text: Fmt.bytes(app.trashLog.totalReclaimed), color: .red)
        }
    }
}
