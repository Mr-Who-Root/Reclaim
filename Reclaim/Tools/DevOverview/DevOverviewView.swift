import SwiftUI

struct DevOverviewView: View {
    @Bindable private var model = AppModel.shared.devOverview
    private var processes: DevProcessesModel { AppModel.shared.processes }

    var body: some View {
        VStack(spacing: 0) {
            ToolHeader(route: .dev, subtitle: subtitle) {
                if model.phase.isDone {
                    Button { Task { await model.scan() } } label: { Label("Scan Again", systemImage: "arrow.clockwise") }
                }
            }
            content
        }
    }

    private var subtitle: String {
        guard model.phase.isDone else { return Route.dev.tagline }
        return String(localized: "\(Fmt.bytes(model.totalBytes)) across \(Fmt.count(model.areas.count, "area")) · scanned \(Fmt.relative(model.phase.lastScan))")
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .idle, .failed:
            ToolIntro(route: .dev,
                      title: "Everything development takes up",
                      message: "Xcode, Android, Docker, language versions, package caches, build output and AI models, measured in one pass, with what each developer tool found to review.",
                      bullets: ["Only measures and reports; nothing is changed",
                                "Runs the developer tools that haven't scanned yet",
                                "Each area links to the tool that can clear it"],
                      buttonTitle: AccessCenter.shared.homeGranted ? "Scan Developer Tools" : "Grant Access & Scan",
                      action: { AccessCenter.shared.ensureAccess { Task { await model.scan() } } })
        case .scanning(let message):
            ScanningPanel(title: "Measuring developer tools", message: message)
        case .done:
            ScrollView {
                VStack(spacing: 14) {
                    HStack(spacing: 12) {
                        StatTile(title: "Developer tools use", value: Fmt.bytes(model.totalBytes),
                                 caption: String(localized: "Measured on disk"), tint: .primary)
                        StatTile(title: "To review", value: Fmt.bytes(model.reviewBytes),
                                 caption: String(localized: "Found by each tool's scan"))
                        Button { AppModel.shared.route = .processes } label: {
                            StatTile(title: "Left-behind processes",
                                     value: processes.leftBehind.isEmpty ? String(localized: "None") : "\(processes.leftBehind.count)",
                                     caption: processes.leftBehind.isEmpty ? String(localized: "Nothing running on its own")
                                         : String(localized: "Using \(Fmt.bytes(processes.leftBehindMemory)) of memory"),
                                     tint: processes.leftBehind.isEmpty ? .green : .orange)
                        }
                        .buttonStyle(.plain)
                    }
                    if model.areas.isEmpty {
                        AllClearView(title: "No developer tools found", message: "Reclaim didn't find Xcode, Android, Docker or language toolchains on this Mac.")
                    } else {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack(spacing: 14) {
                                SectionTitle(title: "By area", subtitle: "Biggest first. Hover a bar for exact numbers.")
                                legend(color: .accentColor, "To review")
                                legend(color: .secondary.opacity(0.35), "Everything else")
                            }
                            let maxTotal = model.areas.first?.total ?? 1
                            ForEach(Array(model.areas.enumerated()), id: \.element.id) { index, area in
                                if index > 0 { RowDivider(inset: 44) }
                                DevAreaRow(area: area, maxTotal: maxTotal)
                            }
                        }
                        .card(padding: 16)
                    }
                    Label("Totals are measured on disk. \"To review\" comes from Junk, AI Junk, Docker, SDKs & Toolchains and Git & Homebrew; open one to decide what to clear.",
                          systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(20)
            }
        }
    }

    private func legend(color: Color, _ title: LocalizedStringKey) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .fixedSize()
    }
}

private struct DevAreaRow: View {
    let area: DevOverviewModel.Area
    let maxTotal: Int64

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: area.icon)
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(area.color.gradient))
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(area.title).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text(Fmt.bytes(area.total)).font(.callout.weight(.semibold)).monospacedDigit()
                }
                bar
                    .help(String(localized: "\(area.title): \(Fmt.bytes(area.total)) in total, \(Fmt.bytes(area.reviewBytes)) to review"))
                HStack(spacing: 8) {
                    Text(area.reviewBytes > 0 ? String(localized: "\(Fmt.bytes(area.reviewBytes)) to review") : String(localized: "Nothing to review"))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    review
                }
            }
        }
    }

    private var bar: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let totalWidth = max(4, width * CGFloat(Double(area.total) / Double(max(maxTotal, 1))))
            let reviewWidth = area.reviewBytes > 0 ? max(4, totalWidth * CGFloat(Double(area.reviewBytes) / Double(max(area.total, 1)))) : 0
            HStack(spacing: 2) {
                if reviewWidth > 0 {
                    RoundedRectangle(cornerRadius: 3).fill(Color.accentColor).frame(width: min(reviewWidth, totalWidth))
                }
                if totalWidth - reviewWidth > 2 {
                    RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.35)).frame(width: totalWidth - reviewWidth - (reviewWidth > 0 ? 2 : 0))
                }
            }
        }
        .frame(height: 8)
    }

    @ViewBuilder private var review: some View {
        let routes = Array(Set(area.parts.map(\.route)))
        if routes.count == 1, let route = routes.first {
            Button(String(localized: "Open \(route.title)")) { AppModel.shared.route = route }
                .buttonStyle(.link).font(.caption)
        } else if routes.count > 1 {
            Menu("Review") {
                ForEach(area.parts) { part in
                    Button("\(part.title) · \(Fmt.bytes(part.bytes))") { AppModel.shared.route = part.route }
                }
            }
            .menuStyle(.borderlessButton).fixedSize().font(.caption)
        }
    }
}
