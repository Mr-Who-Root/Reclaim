import SwiftUI

/// Mac Overview: free space, Smart Scan across every tool, and a card per tool.
struct HomeView: View {
    private var app: AppModel { AppModel.shared }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HomeHero()
                if app.smartScanRunning || app.lastSmartScan != nil {
                    SmartScanResults()
                }
                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle(title: "Tools", subtitle: "Look first, decide yourself, then reclaim. Every tool is unlocked.")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 12)], spacing: 12) {
                        ForEach(Route.allCases.filter { $0 != .home }) { route in
                            ToolCard(route: route)
                        }
                    }
                }
                HomeFooter()
            }
            .padding(24)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
        .onAppear { app.refreshVolume() }
    }
}

private struct HomeHero: View {
    private var app: AppModel { AppModel.shared }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: .now)
        switch hour {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        default: return "Good evening"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 12) {
                Text(greeting).font(.title3).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(Fmt.bytes(app.volume.free)).font(.system(size: 44, weight: .bold, design: .rounded)).monospacedDigit()
                    Text("free of \(Fmt.bytes(app.volume.total))").font(.title3).foregroundStyle(.secondary)
                }
                UsageBar(fraction: app.volume.usedFraction, height: 14)
                HStack(spacing: 16) {
                    Label("\(Fmt.bytes(app.volume.used)) used", systemImage: "circle.fill")
                        .foregroundStyle(.tint)
                    Label("\(Fmt.bytes(app.volume.free)) available", systemImage: "circle")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("Macintosh HD · \(Fmt.percent(app.volume.usedFraction)) full").foregroundStyle(.secondary)
                }
                .font(.caption)
                .labelStyle(.titleAndIcon)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("Smart Scan").font(.headline)
                Text("One pass across every cleanup tool plus a read-only Security Check. Nothing moves until you approve it.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if app.smartScanRunning {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(app.scheduledScanRunning ? "Scheduled scan running…" : "Scanning your Mac…").font(.callout)
                        Spacer()
                        Button("Stop") { app.cancelSmartScan() }
                    }
                } else {
                    Button {
                        app.startSmartScan()
                    } label: {
                        Label(app.lastSmartScan == nil ? "Run Smart Scan" : "Scan Again", systemImage: "sparkle.magnifyingglass")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                if let last = app.lastSmartScan {
                    Text("Last Smart Scan \(Fmt.relative(last))").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(width: 300)
        }
        .card(padding: 20)
    }
}

private struct SmartScanResults: View {
    private var app: AppModel { AppModel.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                SectionTitle(title: app.smartScanRunning ? "Scanning…" : "Found to review",
                             subtitle: app.smartScanRunning ? "Results appear as each tool finishes." : "Nothing has been removed. Open a tool to review its results.")
                Spacer()
                if !app.smartScanRunning {
                    Text(Fmt.bytes(app.totalReclaimable)).font(.title.weight(.bold)).monospacedDigit().foregroundStyle(.tint)
                }
            }
            VStack(spacing: 0) {
                ForEach(app.scanTools, id: \.route) { tool in
                    SmartScanRow(tool: tool)
                    Divider().padding(.leading, 44)
                }
                SecurityRow()
            }
            .card(padding: 6)
            if !app.smartScanRunning, app.totalReclaimable > 0 {
                HStack {
                    Image(systemName: "checklist").foregroundStyle(.indigo)
                    Text("Want help deciding? Guided Cleanup turns these results into a short plan you approve item by item.")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Open Guided Cleanup") { app.route = .guided }
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
            Text("Waiting…").foregroundStyle(.tertiary).font(.caption)
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

private struct ToolCard: View {
    let route: Route
    @State private var hovering = false
    private var app: AppModel { AppModel.shared }

    var body: some View {
        Button {
            app.route = route
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    RouteIcon(route: route, side: 34)
                    Spacer()
                    statusBadge
                }
                Text(route.title).font(.headline)
                Text(route.tagline).font(.caption).foregroundStyle(.secondary).lineLimit(2, reservesSpace: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card(padding: 14)
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(route.color.opacity(hovering ? 0.6 : 0), lineWidth: 1.5))
            .scaleEffect(hovering ? 1.01 : 1)
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
                else { Badge(text: "All clear", color: .green) }
            }
        } else if route == .security, app.security.phase.isDone {
            if app.security.attentionCount > 0 { Badge(text: "\(app.security.attentionCount) to review", color: .orange) }
            else { Badge(text: "Healthy", color: .green) }
        } else if route == .trash, app.trashLog.totalReclaimed > 0 {
            Badge(text: Fmt.bytes(app.trashLog.totalReclaimed), color: .red)
        }
    }
}

private struct HomeFooter: View {
    private var app: AppModel { AppModel.shared }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "leaf.fill").foregroundStyle(.green)
            if app.trashLog.totalReclaimed > 0 {
                Text("\(Text(Fmt.bytes(app.trashLog.totalReclaimed)).fontWeight(.semibold)) cleaned up with Reclaim so far.")
            } else {
                Text("Everything Reclaim removes goes to the Trash, so you can always change your mind.")
            }
            Spacer()
            Button("Review Trash") { app.route = .trash }.buttonStyle(.link)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}
