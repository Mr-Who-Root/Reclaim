import SwiftUI

/// The menu bar panel: free space, memory, CPU, Smart Scan and the last results.
struct MenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var sampler = SystemStatsSampler()
    @State private var cpu: Double?
    @State private var memory: (used: UInt64, total: UInt64)?

    private var app: AppModel { AppModel.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
                    .resizable().frame(width: 22, height: 22)
                Text("Reclaim").font(.headline)
                Spacer()
                Button { openSettings(); NSApp.activate() } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Settings")
            }

            meter(title: "Macintosh HD", value: "\(Fmt.bytes(app.volume.free)) free", fraction: app.volume.usedFraction,
                  caption: "\(Fmt.bytes(app.volume.used)) of \(Fmt.bytes(app.volume.total)) used")
            if let memory {
                meter(title: "Memory", value: "\(Fmt.bytes(Int64(memory.used))) used",
                      fraction: Double(memory.used) / Double(max(memory.total, 1)),
                      caption: "of \(Fmt.bytes(Int64(memory.total)))")
            }
            meter(title: "CPU", value: cpu.map(Fmt.percent) ?? "—", fraction: cpu ?? 0, caption: nil)

            Divider()

            if app.smartScanRunning {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(app.scheduledScanRunning ? "Scheduled scan running…" : "Smart Scan running…")
                    Spacer()
                    Button("Stop") { app.cancelSmartScan() }
                }
                .font(.callout)
            } else {
                Button {
                    app.startSmartScan()
                } label: {
                    Label("Smart Scan", systemImage: "sparkle.magnifyingglass").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            if let last = app.lastSmartScan, !app.smartScanRunning {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Last scan \(Fmt.relative(last))").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(Fmt.bytes(app.totalReclaimable)).font(.caption.weight(.semibold)).monospacedDigit()
                    }
                    ForEach(app.scanTools.filter { $0.reclaimableBytes > 0 }.prefix(5), id: \.route) { tool in
                        Button {
                            open(tool.route)
                        } label: {
                            HStack(spacing: 8) {
                                RouteIcon(route: tool.route, side: 18)
                                Text(tool.route.title)
                                Spacer()
                                Text(Fmt.bytes(tool.reclaimableBytes)).foregroundStyle(.secondary).monospacedDigit()
                            }
                            .font(.callout)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if app.trashLog.totalReclaimed > 0 {
                Label("\(Fmt.bytes(app.trashLog.totalReclaimed)) cleaned up with Reclaim", systemImage: "leaf.fill")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Divider()

            HStack {
                Button("Open Reclaim") { open(nil) }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
        }
        .padding(16)
        .frame(width: 300)
        .task {
            app.refreshVolume()
            _ = sampler.cpuUsage()
            while !Task.isCancelled {
                memory = sampler.memory()
                cpu = sampler.cpuUsage() ?? cpu
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func open(_ route: Route?) {
        if let route { app.route = route }
        openWindow(id: "main")
        NSApp.activate()
    }

    private func meterTint(_ fraction: Double) -> Color? {
        if fraction > 0.9 { return .red }
        if fraction > 0.75 { return .orange }
        return nil
    }

    private func meter(title: String, value: String, fraction: Double, caption: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption.weight(.semibold))
                Spacer()
                Text(value).font(.caption).monospacedDigit()
            }
            UsageBar(fraction: fraction, tint: meterTint(fraction), height: 6)
            if let caption { Text(caption).font(.caption2).foregroundStyle(.secondary) }
        }
    }
}
