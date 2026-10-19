import SwiftUI

@MainActor @Observable
final class AIJunkModel: ScanTool {
    let route: Route = .ai
    var phase: ScanPhase = .idle

    private(set) var items: [AIJunkItem] = []
    private(set) var skippedRecent = 0
    private(set) var skippedRecentBytes: Int64 = 0
    private(set) var openCheckAvailable = true
    private(set) var blocked: [String] = []
    var selection: Set<String> = []
    var collapsed: Set<AIJunkCategory> = []
    var isTrashing = false
    /// Temp files, sessions and logs touched more recently than this are left alone.
    private(set) var idleDays: Int = UserDefaults.standard.object(forKey: PrefKey.aiIdleDays) as? Int ?? 3

    static let idleChoices = [1, 3, 7, 30]

    private var work: Task<AIJunkScanResult, Never>?

    /// Safe items nothing has open — what's preselected.
    private var recommended: [AIJunkItem] {
        items.filter { isRecommended($0) }
    }

    private func isRecommended(_ item: AIJunkItem) -> Bool {
        item.safety == .safe && item.isSelectable && item.category != .models && item.category != .generated
            && (openCheckAvailable || item.category != .caches)
    }

    var reclaimableBytes: Int64 { recommended.reduce(0) { $0 + $1.bytes } }
    var itemCount: Int { recommended.count }

    func setIdleDays(_ days: Int) {
        guard days != idleDays else { return }
        idleDays = days
        UserDefaults.standard.set(days, forKey: PrefKey.aiIdleDays)
        if phase.isDone { Task { await scan() } }
    }

    func scan() async {
        work?.cancel()
        phase = .scanning("Starting…")
        let reporter = ProgressReporter { [weak self] message in
            guard let self, self.phase.isScanning else { return }
            self.phase = .scanning(message)
        }
        let days = idleDays
        let task = Task.detached(priority: .userInitiated) { AIJunkScanner.run(idleDays: days, reporter: reporter) }
        work = task
        let result = await task.value
        guard work == task else { return }
        work = nil
        if task.isCancelled {
            phase = items.isEmpty ? .idle : .done(.now)
            return
        }
        items = result.items
        skippedRecent = result.skippedRecent
        skippedRecentBytes = result.skippedRecentBytes
        openCheckAvailable = result.openCheckAvailable
        blocked = result.blocked
        selectRecommended()
        phase = .done(.now)
    }

    func cancelScan() { work?.cancel() }

    func suggestions() -> [CleanupSuggestion] {
        let modelCutoff = Date().addingTimeInterval(-90 * 86_400)
        let picks = items.filter { item in
            guard item.isSingleTarget, item.isSelectable, item.bytes >= 5_000_000 else { return false }
            if isRecommended(item) { return true }
            return item.category == .models && item.bytes >= 1_000_000_000 && (item.lastActivity ?? .now) < modelCutoff
        }
        return picks.sorted { $0.bytes > $1.bytes }.prefix(25).map { item in
            let confidence: CleanupSuggestion.Confidence
            switch item.category {
            case .temp, .caches: confidence = .high
            case .agents: confidence = .medium
            case .models, .generated: confidence = .lower
            }
            var evidence = [Fmt.bytes(item.bytes), "From \(item.source)", "In \(FS.abbreviate(item.url.deletingLastPathComponent().path))"]
            if let last = item.lastActivity { evidence.insert("Untouched for \(Fmt.age(last))", at: 1) }
            return CleanupSuggestion(tool: .ai, title: "\(item.source): \(item.title)", reason: item.detail, evidence: evidence,
                                     url: item.url, bytes: item.bytes, modified: item.isDirectory ? nil : item.lastActivity,
                                     confidence: confidence)
        }
    }

    func forget(paths: Set<String>) {
        items.removeAll { item in item.targets.contains { paths.containsPathOrAncestor(of: $0.url.path) } }
        selection = selection.filter { id in items.contains { $0.id == id } }
    }

    // MARK: Presentation

    struct Section: Identifiable {
        let category: AIJunkCategory
        let items: [AIJunkItem]
        var id: String { category.id }
        var bytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
    }

    var sections: [Section] {
        AIJunkCategory.allCases.compactMap { c in
            let list = items.filter { $0.category == c }
            return list.isEmpty ? nil : Section(category: c, items: list)
        }
    }

    var foundBytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
    var selectedItems: [AIJunkItem] { items.filter { selection.contains($0.id) } }
    var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.bytes } }

    enum CheckState { case none, some, all }

    func state(of section: Section) -> CheckState {
        let selectable = section.items.filter(\.isSelectable)
        let n = selectable.filter { selection.contains($0.id) }.count
        if n == 0 { return .none }
        return n == selectable.count ? .all : .some
    }

    func toggle(_ section: Section) {
        let ids = section.items.filter(\.isSelectable).map(\.id)
        if state(of: section) == .all { selection.subtract(ids) } else { selection.formUnion(ids) }
    }

    func toggle(_ item: AIJunkItem) {
        guard item.isSelectable else { return }
        if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
    }

    func toggleCollapsed(_ category: AIJunkCategory) {
        if collapsed.contains(category) { collapsed.remove(category) } else { collapsed.insert(category) }
    }

    func selectRecommended() { selection = Set(recommended.map(\.id)) }
    func selectAll() { selection = Set(items.filter(\.isSelectable).map(\.id)) }
    func selectNone() { selection.removeAll() }

    func trashSelected() async {
        let chosen = selectedItems
        guard !chosen.isEmpty, !isTrashing else { return }
        isTrashing = true
        defer { isTrashing = false }
        let targets = chosen.flatMap(\.targets).map { (url: $0.url, bytes: $0.bytes) }
        let moved = await AppModel.shared.trash(targets, from: .ai)
        guard !moved.isEmpty else { return }
        forget(paths: moved)
    }
}
