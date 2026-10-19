import SwiftUI

struct ToolchainsView: View {
    @Bindable private var model = AppModel.shared.toolchains
    @State private var confirmingRuntime: ToolVersion?

    var body: some View {
        VStack(spacing: 0) {
            ToolHeader(route: .toolchains, subtitle: subtitle) {
                if model.phase.isDone {
                    Button { Task { await model.scan() } } label: { Label("Scan Again", systemImage: "arrow.clockwise") }
                }
            }
            content
        }
        .alert(confirmingRuntime.map { String(localized: "Delete \($0.name)?") } ?? "",
               isPresented: Binding(get: { confirmingRuntime != nil }, set: { if !$0 { confirmingRuntime = nil } }),
               presenting: confirmingRuntime) { v in
            Button(String(localized: "Delete \(Fmt.bytes(v.bytes))"), role: .destructive) { Task { await model.deleteRuntime(v) } }
            Button("Cancel", role: .cancel) {}
        } message: { v in
            Text("Reclaim will run:\nxcrun simctl runtime delete \(v.simID ?? "")\n\nSimulator runtimes live in a system disk image, so this doesn't go to the Trash. Download it again in Xcode › Settings › Components.")
        }
    }

    private var subtitle: String {
        guard model.phase.isDone, !model.versions.isEmpty else { return Route.toolchains.tagline }
        return String(localized: "\(Fmt.bytes(model.totalBytes)) installed · \(Fmt.bytes(model.removableBytes)) nothing needs · scanned \(Fmt.relative(model.phase.lastScan))")
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .idle, .failed:
            ToolIntro(route: .toolchains,
                      title: "Clear out old SDKs and toolchains",
                      message: "Android NDKs, SDK platforms, simulator runtimes, JDKs and Node, Python, Ruby, Rust and Go versions pile up as projects move on. Reclaim shows each version and what still needs it.",
                      bullets: ["Keeps the default version, the newest and anything running",
                                "Keeps every version a project asks for (.nvmrc, .python-version, ndkVersion…)",
                                "Old versions go to the Trash, so you can undo"],
                      buttonTitle: AccessCenter.shared.homeGranted ? "Scan" : "Grant Access & Scan",
                      action: { AccessCenter.shared.ensureAccess { Task { await model.scan() } } })
        case .scanning(let message):
            ScanningPanel(title: "Looking for SDKs and toolchains", message: message, onCancel: { model.cancelScan() })
        case .done:
            if model.versions.isEmpty {
                AllClearView(title: "No SDKs or toolchains found",
                             message: "Reclaim didn't find Android SDK parts, simulator runtimes, extra Xcodes, JDKs or version managers on this Mac.",
                             action: { Task { await model.scan() } })
            } else {
                results
            }
        }
    }

    private var results: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 14) {
                    ForEach(model.sections) { section in
                        ResultGroupCard {
                            ResultGroupHeader(icon: section.family.icon, title: section.family.title,
                                              subtitle: section.family.explanation, total: Fmt.bytes(section.bytes))
                        } content: {
                            ForEach(section.versions) { v in
                                RowDivider(inset: 34)
                                ToolVersionRow(version: v, isSelected: model.selection.contains(v.id),
                                               isDeleting: model.deletingRuntime == v.id,
                                               toggle: { model.toggle(v) },
                                               deleteRuntime: { confirmingRuntime = v },
                                               uninstall: { model.uninstall(v) })
                            }
                        }
                    }
                    Label("Reclaim keeps the default version, the newest, anything in use and every version your projects ask for. A project outside your code folders may still need an older one.",
                          systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(20)
            }
            SelectionBar(count: model.selection.count, bytes: model.selectedBytes, isWorking: model.isWorking,
                         action: { Task { await model.trashSelected() } }) {
                Menu("Select") {
                    Button("Recommended (Safe)") { model.selectRecommended() }
                    Button("Everything Nothing Needs") { model.selectAllRemovable() }
                    Divider()
                    Button("None") { model.selectNone() }
                }
                .fixedSize()
            }
        }
    }
}

private struct ToolVersionRow: View {
    let version: ToolVersion
    let isSelected: Bool
    let isDeleting: Bool
    let toggle: () -> Void
    let deleteRuntime: () -> Void
    let uninstall: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if version.isTrashable {
                Toggle("", isOn: Binding(get: { isSelected }, set: { _ in toggle() }))
                    .toggleStyle(.checkbox).labelsHidden()
                    .frame(width: 24)
            } else {
                Color.clear.frame(width: 24, height: 1)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(version.name).lineLimit(1).truncationMode(.middle)
                    Badge(text: version.source)
                    if let reason = version.keepReason {
                        Badge(text: reason, color: .green)
                    } else if !version.isSafe {
                        Badge(text: "Check first", color: .orange)
                    }
                }
                Text(version.note ?? FS.abbreviate(version.url.path))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 12)
            Text(Fmt.bytes(version.bytes)).font(.callout).monospacedDigit().foregroundStyle(.secondary)
            if version.isRemovable {
                switch version.removal {
                case .simctl:
                    if isDeleting { ProgressView().controlSize(.small) } else { Button("Delete…", action: deleteRuntime).buttonStyle(.softGlass) }
                case .uninstallApp:
                    Button("Uninstall…", action: uninstall).buttonStyle(.softGlass)
                default:
                    EmptyView()
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if version.isTrashable { toggle() } }
        .contextMenu {
            Button("Show in Finder") { FS.reveal([version.url]) }
        }
    }
}
