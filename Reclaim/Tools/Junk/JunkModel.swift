import SwiftUI

/// Finds caches, logs, developer leftovers and old backups using `JunkRules`.
@MainActor @Observable
final class JunkModel: ScanTool {
    let route: Route = .junk
    var phase: ScanPhase = .idle

    private(set) var results: [JunkRuleResult] = []
    /// Rules whose folders exist but need Full Disk Access to read.
    private(set) var blockedRules: [String] = []
    var selection: Set<String> = []
    var expanded: Set<String> = []
    private(set) var isTrashing = false

    /// When off, rules marked Caution are hidden and deselected.
    var showCaution = true {
        didSet {
            guard !showCaution else { return }
            for result in results where result.rule.safety == .caution {
                for item in result.items { selection.remove(item.id) }
            }
        }
    }

    private var work: Task<JunkScanOutput, Never>?
    private var lastScan: Date?

    // MARK: ScanTool

    var reclaimableBytes: Int64 {
        results.filter { $0.rule.isRecommended }.reduce(0) { $0 + $1.bytes }
    }

    var itemCount: Int {
        results.filter { $0.rule.isRecommended }.reduce(0) { $0 + $1.items.count }
    }

    func scan() async {
        work?.cancel()
        phase = .scanning("Looking through your Library…")
        let reporter = ProgressReporter { [weak self] message in
            guard let self, self.phase.isScanning else { return }
            self.phase = .scanning(message)
        }
        let rules = JunkRules.all
        let task = Task.detached(priority: .userInitiated) {
            JunkScanner.run(rules: rules, reporter: reporter)
        }
        work = task
        let output = await task.value
        guard work == task else { return }
        work = nil
        if task.isCancelled {
            phase = lastScan.map { .done($0) } ?? .idle
            return
        }
        results = output.results
        blockedRules = output.blockedRules
        selection = Set(results.filter { $0.rule.isRecommended }.flatMap { $0.items.map(\.id) })
        expanded = expanded.filter { id in results.contains { $0.id == id } }
        lastScan = .now
        dropExcluded()
        phase = .done(.now)
    }

    func cancelScan() {
        work?.cancel()
    }

    func suggestions() -> [CleanupSuggestion] {
        var out: [CleanupSuggestion] = []
        for result in results {
            let rule = result.rule
            for item in result.items {
                let entry = item.entry
                if rule.isRecommended {
                    guard entry.size >= 20_000_000 else { continue }
                    out.append(CleanupSuggestion(
                        tool: .junk,
                        title: "\(rule.title): \(item.detail ?? entry.name)",
                        reason: rule.explanation,
                        evidence: [Fmt.bytes(entry.size), "In \(entry.parentDisplayPath)", "Marked Safe"],
                        url: entry.url, bytes: entry.size, modified: entry.modified, confidence: .high))
                } else if entry.size >= 1_000_000_000 {
                    out.append(CleanupSuggestion(
                        tool: .junk,
                        title: "\(rule.title): \(item.detail ?? entry.name)",
                        reason: "Marked Caution. " + rule.explanation,
                        evidence: [Fmt.bytes(entry.size), "Last changed \(Fmt.relative(entry.modified))"],
                        url: entry.url, bytes: entry.size, modified: entry.modified, confidence: .lower))
                }
            }
        }
        return Array(out.sorted { $0.bytes > $1.bytes }.prefix(25))
    }

    // MARK: Presentation

    var visibleResults: [JunkRuleResult] {
        showCaution ? results : results.filter { $0.rule.safety == .safe }
    }

    struct GroupSection: Identifiable {
        let group: JunkGroup
        let results: [JunkRuleResult]
        var id: String { group.id }
        var bytes: Int64 { results.reduce(0) { $0 + $1.bytes } }
    }

    var groupedResults: [GroupSection] {
        let visible = visibleResults
        return JunkGroup.allCases.compactMap { group in
            let rs = visible.filter { $0.rule.group == group }
            return rs.isEmpty ? nil : GroupSection(group: group, results: rs)
        }
    }

    var foundBytes: Int64 { visibleResults.reduce(0) { $0 + $1.bytes } }
    var hasCautionResults: Bool { results.contains { $0.rule.safety == .caution } }

    private var allItems: [JunkItem] { results.flatMap(\.items) }

    var selectedItems: [JunkItem] { allItems.filter { selection.contains($0.id) } }
    var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.entry.size } }

    enum CheckState { case none, some, all }

    func state(of result: JunkRuleResult) -> CheckState {
        let n = result.items.filter { selection.contains($0.id) }.count
        if n == 0 { return .none }
        return n == result.items.count ? .all : .some
    }

    func toggleRule(_ result: JunkRuleResult) {
        let ids = result.items.map(\.id)
        if state(of: result) == .all {
            selection.subtract(ids)
        } else {
            selection.formUnion(ids)
        }
    }

    func toggleItem(_ item: JunkItem) {
        if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
    }

    func toggleExpanded(_ result: JunkRuleResult) {
        if expanded.contains(result.id) { expanded.remove(result.id) } else { expanded.insert(result.id) }
    }

    func selectRecommended() {
        selection = Set(results.filter { $0.rule.isRecommended }.flatMap { $0.items.map(\.id) })
    }

    func selectAllVisible() {
        selection = Set(visibleResults.flatMap { $0.items.map(\.id) })
    }

    func selectNone() { selection.removeAll() }

    func forget(paths: Set<String>) {
        results = results.compactMap { result in
            var r = result
            r.items.removeAll { paths.containsPathOrAncestor(of: $0.id) }
            return r.items.isEmpty ? nil : r
        }
        selection = selection.filter { !paths.containsPathOrAncestor(of: $0) }
    }

    func trashSelected() async {
        let items = selectedItems
        guard !items.isEmpty, !isTrashing else { return }
        isTrashing = true
        defer { isTrashing = false }
        let selectedPaths = Set(items.map(\.entry.path))
        var entries = items.map(\.entry).filter { !selectedPaths.containsPathOrAncestor(of: $0.url.deletingLastPathComponent().path) }
        for item in items {
            entries += item.companions.map { FileEntry(url: $0, size: 0, modified: nil, created: nil, isDirectory: false) }
        }
        let moved = await AppModel.shared.trash(entries, from: .junk)
        guard !moved.isEmpty else { return }
        selection.subtract(moved)
        results = results.compactMap { result in
            var r = result
            r.items.removeAll { moved.contains($0.id) }
            return r.items.isEmpty ? nil : r
        }
    }
}
