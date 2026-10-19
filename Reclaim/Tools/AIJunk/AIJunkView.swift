import SwiftUI
import QuickLook

struct AIJunkView: View {
    @Bindable private var model = AppModel.shared.aiJunk
    @State private var preview: URL?

    var body: some View {
        VStack(spacing: 0) {
            ToolHeader(route: .ai, subtitle: subtitle) {
                Menu {
                    ForEach(AIJunkModel.idleChoices, id: \.self) { days in
                        Button {
                            model.setIdleDays(days)
                        } label: {
                            if days == model.idleDays { Label(idleLabel(days), systemImage: "checkmark") } else { Text(idleLabel(days)) }
                        }
                    }
                } label: {
                    Label("Untouched for \(idleLabel(model.idleDays))", systemImage: "clock")
                }
                .fixedSize()
                .help("Temp files, sessions and logs changed more recently than this are left alone")
                if model.phase.isDone {
                    Button { Task { await model.scan() } } label: { Label("Scan Again", systemImage: "arrow.clockwise") }
                }
            }
            content
        }
        .quickLookPreview($preview)
    }

    private func idleLabel(_ days: Int) -> String {
        switch days {
        case 1: return "1 day"
        case 7: return "1 week"
        case 30: return "1 month"
        default: return "\(days) days"
        }
    }

    private var subtitle: String {
        if model.phase.isDone, !model.items.isEmpty {
            return "Found \(Fmt.bytes(model.foundBytes)) left behind by AI tools · scanned \(Fmt.relative(model.phase.lastScan))"
        }
        return Route.ai.tagline
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .idle, .failed:
            ToolIntro(route: .ai,
                      title: "Clear what AI tools leave behind",
                      message: "Coding agents, chat apps and local model runners fill your Mac with scratch folders, browser profiles, session logs, caches and multi-gigabyte model downloads. Reclaim finds them and explains each one.",
                      bullets: ["Only lists temp files nothing has touched for \(idleLabel(model.idleDays))",
                                "Leaves alone anything a running app has open",
                                "Models and conversation histories are never selected for you",
                                "Everything goes to the Trash, so you can undo"],
                      buttonTitle: AccessCenter.shared.homeGranted ? "Scan for AI Junk" : "Grant Access & Scan",
                      action: { AccessCenter.shared.ensureAccess { Task { await model.scan() } } })
        case .scanning(let message):
            ScanningPanel(title: "Looking for AI leftovers", message: message, onCancel: { model.cancelScan() })
        case .done:
            if model.items.isEmpty {
                AllClearView(title: "No AI junk found",
                             message: skippedNote ?? "Nothing left behind by AI tools needs your attention. Scanned \(Fmt.relative(model.phase.lastScan)).",
                             action: { Task { await model.scan() } })
            } else {
                results
            }
        }
    }

    private var skippedNote: String? {
        guard model.skippedRecent > 0 else { return nil }
        return "\(Fmt.count(model.skippedRecent, "recently used item")) (\(Fmt.bytes(model.skippedRecentBytes))) left alone because it changed in the last \(idleLabel(model.idleDays))."
    }

    private var results: some View {
        VStack(spacing: 0) {
            notices
            List {
                ForEach(model.sections) { section in
                    Section {
                        AIJunkCategoryRow(section: section, model: model)
                        if !model.collapsed.contains(section.category) {
                            ForEach(section.items) { item in
                                AIJunkItemRow(item: item, isSelected: model.selection.contains(item.id),
                                              toggle: { model.toggle(item) },
                                              preview: { preview = $0 })
                                    .padding(.leading, 34)
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)

            SelectionBar(count: model.selection.count, bytes: model.selectedBytes, isWorking: model.isTrashing,
                         action: { Task { await model.trashSelected() } }) {
                Menu("Select") {
                    Button("Recommended (Safe)") { model.selectRecommended() }
                    Button("Everything Not in Use") { model.selectAll() }
                    Divider()
                    Button("None") { model.selectNone() }
                }
                .fixedSize()
            }
        }
    }

    @ViewBuilder private var notices: some View {
        VStack(spacing: 8) {
            if !model.openCheckAvailable {
                Label("Reclaim couldn't check which files running apps have open, so app caches aren't selected for you. Quit AI apps before clearing their caches.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card(padding: 10)
            }
            if !model.blocked.isEmpty {
                FullDiskAccessBanner(reason: "\(model.blocked.joined(separator: " and ")) can only be measured with Full Disk Access.")
            }
            if let skippedNote {
                Label(skippedNote, systemImage: "clock")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 6)
    }
}

private struct AIJunkCategoryRow: View {
    let section: AIJunkModel.Section
    let model: AIJunkModel

    var body: some View {
        let collapsed = model.collapsed.contains(section.category)
        HStack(alignment: .center, spacing: 10) {
            Button {
                model.toggleCollapsed(section.category)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                    .frame(width: 14, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel(collapsed ? "Shows individual items" : "Hides individual items")

            AIJunkCheckbox(state: model.state(of: section)) { model.toggle(section) }

            Image(systemName: section.category.icon).frame(width: 22).foregroundStyle(Route.ai.color)
            VStack(alignment: .leading, spacing: 3) {
                Text(section.category.title).font(.headline)
                Text(section.category.explanation).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Text(Fmt.count(section.items.count, "item")).font(.caption).foregroundStyle(.secondary)
            Text(Fmt.bytes(section.bytes)).monospacedDigit().fontWeight(.semibold).frame(width: 84, alignment: .trailing)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture { model.toggleCollapsed(section.category) }
    }
}

private struct AIJunkItemRow: View {
    let item: AIJunkItem
    let isSelected: Bool
    let toggle: () -> Void
    let preview: (URL) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { isSelected }, set: { _ in toggle() }))
                .toggleStyle(.checkbox).labelsHidden()
                .disabled(!item.isSelectable)
                .accessibilityLabel(isSelected ? "Selected for removal" : "Not selected for removal")
            if item.category == .generated {
                ThumbnailView(url: item.url, side: 30, cornerRadius: 5)
            } else {
                FileIconView(url: item.url, side: 30)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.title).lineLimit(1).truncationMode(.middle)
                    Badge(text: item.source, color: Route.ai.color)
                    Badge(text: item.safety.label, color: item.safety.color)
                    if let user = item.inUseBy {
                        Badge(text: "Open in \(user)", color: .red)
                            .help("A running app has this open. Quit it, then scan again.")
                    }
                }
                Text(item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Text(Fmt.bytes(item.bytes)).monospacedDigit().fontWeight(.medium).frame(width: 84, alignment: .trailing)
        }
        .padding(.vertical, 3)
        .opacity(item.isSelectable ? 1 : 0.6)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { preview(item.url) }
        .contextMenu {
            if item.isSelectable { Button(isSelected ? "Deselect" : "Select", action: toggle) }
            Divider()
            Button("Quick Look") { preview(item.url) }
            Button("Reveal in Finder") { FS.reveal(item.targets.count > 1 && item.targets.count <= 20 ? item.targets.map(\.url) : [item.url]) }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.url.path, forType: .string)
            }
        }
    }
}

private struct AIJunkCheckbox: View {
    let state: AIJunkModel.CheckState
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: state == .none ? "square" : (state == .some ? "minus.square.fill" : "checkmark.square.fill"))
                .font(.system(size: 15))
                .foregroundStyle(state == .none ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(state == .all ? "Deselects every item in this group" : "Selects every item in this group")
    }
}
