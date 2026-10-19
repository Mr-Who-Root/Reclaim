import SwiftUI
import QuickLook

struct GuidedView: View {
    @Bindable private var model = AppModel.shared.guided

    var body: some View {
        VStack(spacing: 0) {
            ToolHeader(route: .guided, subtitle: subtitle) {
                if model.stage == .review {
                    Button {
                        model.showAssistant.toggle()
                    } label: {
                        Label("Ask About This Review", systemImage: "bubble.left.and.text.bubble.right")
                    }
                    .help("Opens an on-device assistant that can answer questions about this review and add suggestions to your plan.")
                }
            }
            GuidedStepper(stage: model.stage)
            Divider()
            content
        }
        .sheet(isPresented: $model.showConfirm) {
            GuidedConfirmSheet(model: model)
        }
        .inspector(isPresented: $model.showAssistant) {
            GuidedAssistantPanel(model: model)
                .inspectorColumnWidth(min: 300, ideal: 360, max: 480)
        }
    }

    private var subtitle: String {
        switch model.stage {
        case .areas: return "Reclaim proposes, you approve every action before anything moves"
        case .auditing: return "Checking your Mac. Nothing is being changed."
        case .review: return "Review each suggestion. Adding to the plan doesn't carry it out."
        case .running: return "Carrying out only the actions you confirmed"
        case .results: return "What Reclaim did, and how to undo it"
        }
    }

    @ViewBuilder private var content: some View {
        switch model.stage {
        case .areas:
            GuidedAreasStep(model: model)
        case .auditing:
            GuidedAuditStep(model: model)
        case .review:
            if model.suggestions.isEmpty {
                AllClearView(title: "Your Mac looks clear",
                             message: model.failedAreas.isEmpty
                                ? "The selected areas have no suggestions for you right now. Reclaim only recommends an action when it has a clear reason to."
                                : "Nothing to suggest from the areas that could be checked. Some areas couldn't be checked — try them again later.",
                             actionTitle: "Start Another Audit",
                             action: { model.finishWithoutChanges() })
            } else {
                GuidedReviewStep(model: model)
            }
        case .running:
            VStack(spacing: 14) {
                ProgressView().controlSize(.large)
                Text("Carrying out your confirmed plan").font(.title3.weight(.semibold))
                Text("Only the actions you confirmed are being requested.").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .results:
            GuidedResultsStep(model: model)
        }
    }
}

// MARK: - Stepper

private struct GuidedStepper: View {
    let stage: GuidedModel.Stage

    private let steps: [(String, GuidedModel.Stage)] = [
        ("Choose areas", .areas), ("Audit", .auditing), ("Review", .review), ("Run", .running), ("Done", .results),
    ]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                let reached = stage >= step.1
                let current = stage == step.1
                HStack(spacing: 6) {
                    ZStack {
                        Circle().fill(reached ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                        if stage > step.1 {
                            Image(systemName: "checkmark").font(.caption2.weight(.bold)).foregroundStyle(.white)
                        } else {
                            Text("\(index + 1)").font(.caption2.weight(.bold)).foregroundStyle(reached ? .white : .secondary)
                        }
                    }
                    .frame(width: 20, height: 20)
                    Text(step.0).font(.caption.weight(current ? .semibold : .regular))
                        .foregroundStyle(current ? .primary : .secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(current ? .isSelected : [])
                if index < steps.count - 1 {
                    Rectangle().fill(.quaternary).frame(height: 1).frame(maxWidth: 40)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
    }
}

// MARK: - Step 1: areas

private struct GuidedAreasStep: View {
    @Bindable var model: GuidedModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 12) {
                    GuidedPromise(icon: "magnifyingglass", title: "Audit", text: "Checks the selected areas on this Mac without changing anything.")
                    GuidedPromise(icon: "list.bullet.rectangle", title: "Review", text: "Shows a short list with evidence, impact and the exact action.")
                    GuidedPromise(icon: "checkmark.circle", title: "Run", text: "Carries out only the actions in your final plan.")
                }

                SectionTitle(title: "What this audit checks", subtitle: "Reclaim does the searching. Every decision stays with you.")

                VStack(spacing: 0) {
                    ForEach(GuidedArea.allCases) { area in
                        GuidedAreaRow(area: area, isOn: Binding(
                            get: { model.enabled.contains(area) },
                            set: { on in if on { model.enabled.insert(area) } else { model.enabled.remove(area) } }
                        ), tool: model.tool(for: area))
                        if area != GuidedArea.allCases.last { Divider().padding(.leading, 56) }
                    }
                }
                .card(padding: 8)

                HStack(spacing: 12) {
                    Button {
                        model.startAudit()
                    } label: {
                        Label("Start Audit", systemImage: "magnifyingglass").padding(.horizontal, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(model.enabled.isEmpty)
                    .keyboardShortcut(.defaultAction)
                    .help("Begins a read-only audit of the selected areas. No cleanup actions are performed.")

                    Text(model.enabled.isEmpty
                         ? "No area is selected. Turn on at least one row to run an audit."
                         : "The audit is read-only. It looks, lists what it found, and stops.")
                        .font(.callout).foregroundStyle(.secondary)
                }

                if !model.history.isEmpty {
                    GuidedHistoryList(model: model)
                }
            }
            .padding(20)
        }
    }
}

private struct GuidedPromise: View {
    let icon: String
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon).font(.title2).foregroundStyle(.tint)
            Text(title).font(.headline)
            Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

private struct GuidedAreaRow: View {
    let area: GuidedArea
    @Binding var isOn: Bool
    let tool: (any ScanTool)?

    var body: some View {
        HStack(spacing: 12) {
            RouteIcon(route: area.route, side: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(area.title).fontWeight(.medium)
                Text(area.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let tool, let last = tool.phase.lastScan {
                    Text("Last checked \(Fmt.relative(last)) · \(Fmt.bytes(tool.reclaimableBytes)) found")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Toggle(area.title, isOn: $isOn).toggleStyle(.switch).labelsHidden()
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 6)
    }
}

private struct GuidedHistoryList: View {
    let model: GuidedModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionTitle(title: "Past cleanups", subtitle: "Only confirmed Trash moves are counted.")
                Button("Clear History") { model.clearHistory() }.buttonStyle(.link)
            }
            VStack(spacing: 0) {
                ForEach(model.history.prefix(8)) { run in
                    HStack {
                        Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
                        Text(Fmt.dateTime(run.date))
                        Spacer()
                        Text(historyText(run)).font(.caption).foregroundStyle(.secondary)
                        Text(Fmt.bytes(run.bytes)).monospacedDigit().fontWeight(.medium).frame(width: 80, alignment: .trailing)
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 6)
                    if run.id != model.history.prefix(8).last?.id { Divider() }
                }
            }
            .card(padding: 8)
        }
    }

    private func historyText(_ run: GuidedRunRecord) -> String {
        var parts = ["\(run.moved) moved"]
        if run.skipped > 0 { parts.append("\(run.skipped) skipped") }
        if run.failed > 0 { parts.append("\(run.failed) failed") }
        if run.declined > 0 { parts.append("\(run.declined) left unchanged") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Step 2: audit

private struct GuidedAuditStep: View {
    let model: GuidedModel

    var body: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 20)
            ProgressView().controlSize(.large)
            Text("Checking your Mac").font(.title2.weight(.semibold))
            Text("Nothing is being changed. Reclaim is only looking.").foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(model.auditedAreas) { area in
                    GuidedAuditRow(area: area, tool: model.tool(for: area))
                    if area != model.auditedAreas.last { Divider().padding(.leading, 48) }
                }
            }
            .card(padding: 8)
            .frame(maxWidth: 560)
            Button("Stop Audit") { model.cancelAudit() }
                .help("Finishes this audit without moving or changing anything.")
            Spacer(minLength: 20)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct GuidedAuditRow: View {
    let area: GuidedArea
    let tool: (any ScanTool)?

    var body: some View {
        HStack(spacing: 12) {
            RouteIcon(route: area.route, side: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(area.title).fontWeight(.medium)
                Text(statusText).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            statusIcon
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 6)
    }

    private var statusText: String {
        guard let tool else { return "No source is available for this area." }
        switch tool.phase {
        case .idle: return "Waiting…"
        case .scanning(let m): return m
        case .done: return tool.itemCount == 0 ? "Nothing found" : "\(Fmt.count(tool.itemCount, "item")) · \(Fmt.bytes(tool.reclaimableBytes))"
        case .failed(let m): return "This source could not be checked. \(m)"
        }
    }

    @ViewBuilder private var statusIcon: some View {
        switch tool?.phase ?? .idle {
        case .scanning: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .idle: Image(systemName: "circle.dotted").foregroundStyle(.secondary)
        }
    }
}

// MARK: - Step 3: review

private struct GuidedReviewStep: View {
    @Bindable var model: GuidedModel
    @State private var preview: URL?

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                ChipPicker(selection: $model.filter, options: model.filterOptions,
                           label: model.label(for:), count: { model.count(for: $0) })
                HStack(spacing: 10) {
                    Picker("Sort", selection: $model.sort) {
                        ForEach(GuidedModel.SortOrder.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .fixedSize()
                    Spacer()
                    Button("Add All in This Filter") { model.addAllVisible() }
                        .help("Adds every undecided suggestion in this filter to the plan. Nothing is carried out yet.")
                    Button("Remove All from Plan") { model.removeAllFromPlan() }
                        .disabled(model.planned.isEmpty)
                        .help("Removes every suggestion from the plan. Decisions to leave items unchanged are kept.")
                }
                .padding(.horizontal, 20)
            }
            .padding(.vertical, 10)

            if !model.failedAreas.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("Couldn't check \(model.failedAreas.map(\.title).sorted().joined(separator: ", ")). Everything that finished is ready to review.")
                        .font(.callout)
                    Spacer()
                }
                .card(padding: 10)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            }

            Divider()

            ScrollView {
                LazyVStack(spacing: 10) {
                    let items = model.visible
                    if items.isEmpty {
                        Text("No suggestions in this filter.").foregroundStyle(.secondary).padding(40)
                    }
                    ForEach(items) { s in
                        GuidedSuggestionCard(suggestion: s,
                                             decision: model.decision(for: s),
                                             onDecide: { model.setDecision($0, for: s) },
                                             onQuickLook: { preview = $0 })
                    }
                }
                .padding(20)
            }
            .quickLookPreview($preview)

            GuidedReviewBar(model: model)
        }
    }
}

private struct GuidedSuggestionCard: View {
    let suggestion: CleanupSuggestion
    let decision: GuidedDecision
    let onDecide: (GuidedDecision) -> Void
    let onQuickLook: (URL) -> Void
    @State private var expanded = false

    private var confidenceColor: Color {
        switch suggestion.confidence {
        case .high: return .green
        case .medium: return .orange
        case .lower: return .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                FileIconView(url: suggestion.url, side: 36)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(suggestion.title).fontWeight(.semibold).lineLimit(1).truncationMode(.middle)
                        Badge(text: GuidedArea.area(for: suggestion.tool)?.title ?? suggestion.tool.title, color: suggestion.tool.color)
                        Badge(text: suggestion.confidence.label, color: confidenceColor)
                    }
                    Text(suggestion.reason).font(.callout).foregroundStyle(.secondary)
                        .lineLimit(expanded ? nil : 2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Text(Fmt.bytes(suggestion.bytes)).font(.title3.weight(.semibold)).monospacedDigit()
            }

            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(suggestion.evidence, id: \.self) { fact in
                        Label(fact, systemImage: "smallcircle.filled.circle").font(.callout)
                    }
                    LabeledContent("Action", value: "Move to Trash (recoverable until you empty it)")
                    LabeledContent("Location") {
                        Text(FS.abbreviate(suggestion.url.path)).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                    }
                    if let modified = suggestion.modified {
                        LabeledContent("Last changed", value: "\(Fmt.date(modified)) (\(Fmt.age(modified)) ago)")
                    }
                    HStack {
                        Button("Reveal in Finder") { FS.reveal([suggestion.url]) }
                        Button("Quick Look") { onQuickLook(suggestion.url) }
                    }
                    .controlSize(.small)
                }
                .font(.callout)
                .padding(.top, 4)
            } label: {
                Text("Why Reclaim suggested this").font(.callout)
            }
            .help("Shows why Reclaim suggested this and the exact action.")

            HStack(spacing: 8) {
                switch decision {
                case .undecided:
                    Button { onDecide(.plan) } label: { Label("Add to Plan", systemImage: "plus.circle") }
                        .buttonStyle(.borderedProminent)
                        .help("Adds this suggestion to the final plan")
                    Button { onDecide(.keep) } label: { Label("Leave Unchanged", systemImage: "hand.raised") }
                        .help("Leave this item unchanged")
                case .plan:
                    Label("In your plan", systemImage: "checkmark.circle.fill").foregroundStyle(.tint).fontWeight(.medium)
                    Button("Remove from Plan") { onDecide(.undecided) }
                        .help("Return this suggestion to undecided")
                case .keep:
                    Label("Left unchanged", systemImage: "hand.raised.fill").foregroundStyle(.secondary)
                    Button("Reconsider") { onDecide(.undecided) }
                        .help("Return this suggestion to undecided")
                }
                Spacer()
            }
            .controlSize(.regular)
        }
        .card()
        .overlay {
            if decision == .plan {
                RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.tint, lineWidth: 2)
            }
        }
        .opacity(decision == .keep ? 0.7 : 1)
        .contextMenu {
            Button("Quick Look") { onQuickLook(suggestion.url) }
            Button("Reveal in Finder") { FS.reveal([suggestion.url]) }
        }
    }
}

private struct GuidedReviewBar: View {
    let model: GuidedModel

    var body: some View {
        HStack(spacing: 12) {
            Button("Finish Without Changes") { model.finishWithoutChanges() }
                .help("Finishes this audit without moving or changing anything.")
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(model.planned.isEmpty ? "Nothing in your plan yet" : "\(Fmt.count(model.planned.count, "item")) in your plan · \(Fmt.bytes(model.plannedBytes))")
                    .fontWeight(.medium)
                Text("\(model.undecidedCount) undecided · \(Fmt.bytes(model.totalBytes)) found in total")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button {
                model.showConfirm = true
            } label: {
                Label("Review Final Plan…", systemImage: "checklist")
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.planned.isEmpty)
            .help("Opens a final confirmation. It does not perform any action yet.")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

// MARK: - Step 4: confirm

private struct GuidedConfirmSheet: View {
    let model: GuidedModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Confirm your plan").font(.title2.weight(.bold))
                Text("These are the only actions Reclaim will request. Close this window to make no changes.")
                    .foregroundStyle(.secondary)
            }

            List(model.planned) { s in
                HStack(spacing: 10) {
                    FileIconView(url: s.url, side: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(s.title).lineLimit(1).truncationMode(.middle)
                        Text("Move to Trash · \(FS.abbreviate(s.url.path))").font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Text(Fmt.bytes(s.bytes)).monospacedDigit()
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .frame(minHeight: 220)

            HStack {
                Text("\(Fmt.count(model.planned.count, "action")) · \(Fmt.bytes(model.plannedBytes)) to the Trash").fontWeight(.semibold)
                Spacer()
            }

            Text("Reclaim will not touch suggestions you kept or left undecided. Each item is checked again first and skipped if it changed since the audit. Everything goes to the Trash and stays recoverable until you empty it.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 2) {
                Toggle("I reviewed this exact plan and want Reclaim to carry out only these actions.", isOn: $confirmed)
                    .toggleStyle(.checkbox)
                Text("Required before the final button becomes available.").font(.caption).foregroundStyle(.secondary)
                    .padding(.leading, 20)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(role: .destructive) {
                    Task { await model.execute() }
                } label: {
                    Text("Move \(Fmt.count(model.planned.count, "Item")) to Trash")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!confirmed)
                .help("This is the final confirmation and begins only the actions in your plan.")
            }
        }
        .padding(22)
        .frame(width: 600, height: 560)
    }
}

// MARK: - Step 5: results

private struct GuidedResultsStep: View {
    let model: GuidedModel
    @State private var showDeclined = false

    var body: some View {
        let moved = model.movedOutcomes
        let skipped = model.outcomes(where: { if case .skipped = $0 { return true }; return false })
        let failed = model.outcomes(where: { if case .failed = $0 { return true }; return false })
        let declined = model.outcomes(where: { $0 == .declined || $0 == .undecided })

        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        Image(systemName: skipped.isEmpty && failed.isEmpty ? "checkmark.seal.fill" : "exclamationmark.circle.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(skipped.isEmpty && failed.isEmpty ? .green : .orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(skipped.isEmpty && failed.isEmpty ? "Your plan is complete" : "Some actions need another look")
                                .font(.title2.weight(.bold))
                            Text("Reclaim completed only the actions in your confirmed plan. Anything that couldn't finish was left unchanged.")
                                .foregroundStyle(.secondary)
                        }
                    }

                    HStack(spacing: 12) {
                        StatTile(title: "Moved to Trash", value: "\(moved.filter { $0.recordID != nil }.count)",
                                 caption: Fmt.bytes(model.movedBytes), tint: .green)
                        StatTile(title: "Skipped", value: "\(skipped.count)", caption: "Changed since the audit",
                                 tint: skipped.isEmpty ? .secondary : .orange)
                        StatTile(title: "Couldn't move", value: "\(failed.count)", caption: "Left unchanged",
                                 tint: failed.isEmpty ? .secondary : .red)
                        StatTile(title: "Not in plan", value: "\(declined.count)", caption: "Untouched", tint: .secondary)
                    }

                    if !moved.isEmpty {
                        GuidedOutcomeSection(title: "Moved to the Trash", outcomes: moved, model: model)
                    }
                    if !skipped.isEmpty || !failed.isEmpty {
                        GuidedOutcomeSection(title: "Why actions did not finish", outcomes: skipped + failed, model: model)
                    }
                    if !declined.isEmpty {
                        DisclosureGroup(isExpanded: $showDeclined) {
                            GuidedOutcomeSection(title: nil, outcomes: declined, model: model)
                        } label: {
                            Text("Left unchanged · \(declined.count)").font(.headline)
                        }
                    }
                }
                .padding(20)
            }

            HStack(spacing: 10) {
                Button {
                    Task { await model.undoAll() }
                } label: {
                    Label("Undo All", systemImage: "arrow.uturn.backward")
                }
                .disabled(!model.canUndoAny || model.isUndoing)
                Button {
                    FS.openTrash()
                } label: {
                    Label("Open Trash in Finder", systemImage: "trash")
                }
                .help("Opens Finder so you can inspect items Reclaim moved to the Trash.")
                Spacer()
                Button("Start Another Audit") { model.startOver() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
        }
    }
}

private struct GuidedOutcomeSection: View {
    let title: String?
    let outcomes: [GuidedOutcome]
    let model: GuidedModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title { Text("\(title) · \(outcomes.count)").font(.headline) }
            VStack(spacing: 0) {
                ForEach(outcomes) { outcome in
                    GuidedOutcomeRow(outcome: outcome, model: model)
                    if outcome.id != outcomes.last?.id { Divider().padding(.leading, 40) }
                }
            }
            .card(padding: 8)
        }
    }
}

private struct GuidedOutcomeRow: View {
    let outcome: GuidedOutcome
    let model: GuidedModel

    var body: some View {
        HStack(spacing: 10) {
            FileIconView(url: outcome.suggestion.url, side: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(outcome.suggestion.title).lineLimit(1).truncationMode(.middle)
                Text(detail).font(.caption).foregroundStyle(detailColor).lineLimit(2)
            }
            Spacer(minLength: 8)
            Text(Fmt.bytes(outcome.suggestion.bytes)).monospacedDigit().foregroundStyle(.secondary)
            trailing
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 4)
    }

    private var detail: String {
        switch outcome.status {
        case .moved: return "In the Trash · recoverable until you empty it"
        case .restored: return "Restored to its original folder"
        case .restoreFailed(let why): return "Couldn't undo: \(why)"
        case .skipped(let why), .failed(let why): return why
        case .declined: return "You chose to leave this unchanged"
        case .undecided: return "Left undecided, so Reclaim didn't touch it"
        }
    }

    private var detailColor: Color {
        switch outcome.status {
        case .skipped, .restoreFailed: return .orange
        case .failed: return .red
        default: return .secondary
        }
    }

    @ViewBuilder private var trailing: some View {
        switch outcome.status {
        case .moved:
            Button("Undo") { Task { await model.undo(outcome) } }
                .disabled(model.isUndoing)
                .help("Restores this item to its original folder.")
        case .restored:
            Image(systemName: "arrow.uturn.backward.circle.fill").foregroundStyle(.green)
        default:
            EmptyView()
        }
    }
}

// MARK: - Assistant

private struct GuidedAssistantPanel: View {
    let model: GuidedModel
    @State private var question = ""
    @FocusState private var focused: Bool

    private var assistant: GuidedAssistant { model.assistant }

    private let starters = [
        "What's the safest to remove?",
        "Which items free the most space?",
        "Is there anything I should keep?",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Label("Ask about this review", systemImage: "sparkles").font(.headline)
                Text("Runs on this Mac with Apple's on-device model. Nothing you ask leaves the device, and it can only suggest — you decide.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            Divider()

            if let reason = assistant.unavailableReason {
                VStack(spacing: 12) {
                    Image(systemName: "apple.intelligence").font(.system(size: 34)).foregroundStyle(.secondary)
                    Text("The assistant isn't available").font(.headline)
                    Text(reason).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Check Again") { assistant.recheckAvailability() }
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            if assistant.messages.isEmpty {
                                Text("Ask about anything in this review.").foregroundStyle(.secondary)
                                ForEach(starters, id: \.self) { s in
                                    Button(s) { send(s) }.buttonStyle(.bordered).controlSize(.small)
                                }
                            }
                            ForEach(assistant.messages) { message in
                                GuidedMessageBubble(message: message, model: model).id(message.id)
                            }
                            if assistant.isResponding {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text("Thinking on this Mac…").font(.caption).foregroundStyle(.secondary)
                                }
                                .id("thinking")
                            }
                        }
                        .padding(14)
                    }
                    .onChange(of: assistant.messages.count) {
                        if let last = assistant.messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                    }
                }
                Divider()
                HStack(spacing: 8) {
                    TextField("Ask about this review", text: $question, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...4)
                        .focused($focused)
                        .onSubmit { send(question) }
                    Button {
                        send(question)
                    } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.title2)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty || assistant.isResponding)
                    .accessibilityLabel("Send")
                }
                .padding(12)
            }
        }
        .onAppear { assistant.recheckAvailability(); focused = true }
    }

    private func send(_ text: String) {
        let q = text
        question = ""
        Task {
            await assistant.ask(q, suggestions: model.suggestions, decision: { model.decision(for: $0) })
        }
    }
}

private struct GuidedMessageBubble: View {
    let message: GuidedAssistant.Message
    let model: GuidedModel

    var body: some View {
        switch message.role {
        case .person:
            HStack {
                Spacer(minLength: 30)
                Text(message.text)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .foregroundStyle(.white)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.tint))
                    .textSelection(.enabled)
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 8) {
                Text(message.text).textSelection(.enabled)
                ForEach(message.suggestionIDs, id: \.self) { id in
                    if let s = model.suggestion(withID: id) {
                        HStack(spacing: 8) {
                            FileIconView(url: s.url, side: 20)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(s.title).font(.caption).lineLimit(1).truncationMode(.middle)
                                Text(Fmt.bytes(s.bytes)).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if model.decision(for: s) == .plan {
                                Label("In plan", systemImage: "checkmark").font(.caption).foregroundStyle(.tint)
                            } else {
                                Button("Add to Plan") { model.setDecision(.plan, for: s) }.controlSize(.small)
                            }
                        }
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(.background))
                    }
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.6)))
        case .notice:
            Label(message.text, systemImage: "info.circle")
                .font(.callout).foregroundStyle(.secondary)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator))
        }
    }
}
