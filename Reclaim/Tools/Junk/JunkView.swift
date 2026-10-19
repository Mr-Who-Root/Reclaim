import SwiftUI

struct JunkView: View {
    @Bindable private var model = AppModel.shared.junk
    @AppStorage(PrefKey.hideDevExplainer) private var hideDevExplainer = false

    var body: some View {
        VStack(spacing: 0) {
            ToolHeader(route: .junk, subtitle: subtitle) {
                if model.phase.isDone {
                    Button {
                        Task { await model.scan() }
                    } label: {
                        Label("Scan Again", systemImage: "arrow.clockwise")
                    }
                }
            }
            content
        }
    }

    private var subtitle: String {
        if model.phase.isDone, !model.results.isEmpty {
            return String(localized: "Found \(Fmt.bytes(model.foundBytes)) in caches, logs and leftovers · scanned \(Fmt.relative(model.phase.lastScan))")
        }
        return String(localized: "Caches, logs, developer leftovers & old iOS backups")
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .idle, .failed:
            ToolIntro(route: .junk,
                      title: "Find junk you can safely clear",
                      message: "Checks app caches, logs, browser caches, developer leftovers and old device backups. Every rule explains why it's safe, and nothing moves without your review.",
                      bullets: ["Apps rebuild caches on their own", "Developer caches rebuild on your next build", "Everything goes to the Trash, so you can undo"],
                      buttonTitle: "Scan for Junk",
                      action: { Task { await model.scan() } })
        case .scanning(let message):
            ScanningPanel(title: "Looking through your Library", message: message, onCancel: { model.cancelScan() })
        case .done:
            if model.results.isEmpty {
                VStack(spacing: 0) {
                    if !model.blockedRules.isEmpty { fdaBanner.padding(.top, 4) }
                    AllClearView(title: "No junk worth clearing",
                                 message: "Caches and logs are all small right now. Scanned \(Fmt.relative(model.phase.lastScan)).",
                                 action: { Task { await model.scan() } })
                }
            } else {
                results
            }
        }
    }

    private var fdaBanner: some View {
        FullDiskAccessBanner(reason: "\(model.blockedRules.joined(separator: " and ")) can only be measured with Full Disk Access.")
    }

    private var results: some View {
        VStack(spacing: 0) {
            if !model.blockedRules.isEmpty { fdaBanner.padding(.bottom, 8) }
            ScrollView {
                LazyVStack(spacing: 14) {
                    ForEach(model.groupedResults) { section in
                        if section.group == .developer, !hideDevExplainer {
                            JunkDevExplainer { hideDevExplainer = true }
                        }
                        ResultGroupCard {
                            ResultGroupHeader(icon: section.group.icon, title: Fmt.loc(section.group.rawValue), total: Fmt.bytes(section.bytes))
                        } content: {
                            ForEach(Array(section.results.enumerated()), id: \.element.id) { index, result in
                                if index > 0 { RowDivider(inset: 0) }
                                JunkRuleRow(result: result, model: model)
                                if model.expanded.contains(result.id) {
                                    ForEach(result.items) { item in
                                        FileRow(entry: item.entry,
                                                isSelected: model.selection.contains(item.id),
                                                detail: item.detail,
                                                toggle: { model.toggleItem(item) })
                                            .padding(.leading, 34)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(20)
            }

            SelectionBar(count: model.selection.count, bytes: model.selectedBytes,
                         isWorking: model.isTrashing,
                         action: { Task { await model.trashSelected() } }) {
                Menu("Select") {
                    Button("Recommended (Safe)") { model.selectRecommended() }
                    Button("Everything Shown") { model.selectAllVisible() }
                    Divider()
                    Button("None") { model.selectNone() }
                }
                .fixedSize()
                if model.hasCautionResults {
                    Toggle("Include items marked Caution", isOn: $model.showCaution)
                        .toggleStyle(.checkbox)
                }
            }
        }
    }
}

/// One rule: tri-state checkbox, explanation, safety badge, total. Click the chevron to see its items.
private struct JunkRuleRow: View {
    let result: JunkRuleResult
    let model: JunkModel

    var body: some View {
        let rule = result.rule
        let expanded = model.expanded.contains(result.id)
        HStack(alignment: .center, spacing: 10) {
            Button {
                model.toggleExpanded(result)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 14, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel(expanded ? "Hides individual items" : "Shows individual items")

            JunkCheckbox(state: model.state(of: result)) { model.toggleRule(result) }

            Image(systemName: rule.icon)
                .frame(width: 22)
                .foregroundStyle(Route.junk.color)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(rule.title).fontWeight(.medium)
                    Badge(text: rule.safety.label, color: rule.safety.color)
                }
                Text(rule.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(expanded ? nil : 1)
                    .help(rule.explanation)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if result.items.count > 1 {
                Text(Fmt.count(result.items.count, "item"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(Fmt.bytes(result.bytes))
                .monospacedDigit().fontWeight(.semibold)
                .frame(width: 84, alignment: .trailing)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { model.toggleExpanded(result) }
        .contextMenu {
            Button(model.state(of: result) == .all ? "Deselect Every Item in This Rule" : "Select Every Item in This Rule") {
                model.toggleRule(result)
            }
            Button("Reveal in Finder") { FS.reveal(result.items.prefix(20).map(\.entry.url)) }
        }
    }
}

/// A checkbox that can show "some selected".
private struct JunkCheckbox: View {
    let state: JunkModel.CheckState
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(state == .none ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var symbol: String {
        switch state {
        case .none: return "square"
        case .some: return "minus.square.fill"
        case .all: return "checkmark.square.fill"
        }
    }

    private var label: String {
        switch state {
        case .none: return String(localized: "Selects every item in this rule")
        case .some: return String(localized: "Some items selected. Selects every item in this rule")
        case .all: return String(localized: "Deselects every item in this rule")
        }
    }
}

private struct JunkDevExplainer: View {
    let onHide: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "hammer.circle.fill").font(.title2).foregroundStyle(.tint)
                Text("What developer caches are").font(.system(.title3, design: .rounded).weight(.semibold))
                Spacer()
                Button(action: onHide) { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Hide this explanation")
                    .accessibilityLabel("Hide this explanation")
            }
            Text("Build intermediates, downloaded packages, and simulator or device-support files from Xcode, npm, Homebrew, Gradle and friends. They rebuild automatically the next time you build or install, and none of them contain your code or projects.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Label("Emulators, simulators and virtual machines are different: they hold data, so they're marked Caution and never selected for you. Old simulator runtimes, NDKs, JDKs and language versions are in SDKs & Toolchains.",
                  systemImage: "info.circle")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Don't show this again", action: onHide)
                .buttonStyle(.link)
                .font(.callout.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 16)
    }
}
