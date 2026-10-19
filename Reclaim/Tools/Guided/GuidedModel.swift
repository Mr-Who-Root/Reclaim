import SwiftUI

/// The places Guided Cleanup can audit, each backed by a cleanup tool.
enum GuidedArea: String, CaseIterable, Identifiable, Codable {
    case downloads, duplicates, junk, ai, large, apps, photos

    var id: String { rawValue }

    var route: Route {
        switch self {
        case .downloads: return .downloads
        case .duplicates: return .duplicates
        case .junk: return .junk
        case .ai: return .ai
        case .large: return .large
        case .apps: return .leftovers
        case .photos: return .photos
        }
    }

    var title: String {
        switch self {
        case .downloads: return String(localized: "Downloads")
        case .duplicates: return String(localized: "Duplicate files")
        case .junk: return String(localized: "Junk")
        case .ai: return String(localized: "AI junk")
        case .large: return String(localized: "Large & old files")
        case .apps: return String(localized: "App leftovers")
        case .photos: return String(localized: "Photo clutter")
        }
    }

    var detail: String {
        switch self {
        case .downloads: return String(localized: "Old installers, archives and large files that have sat in Downloads for months.")
        case .duplicates: return String(localized: "Byte-for-byte identical copies. The suggested keeper is always left untouched.")
        case .junk: return String(localized: "App caches, logs and developer leftovers that rebuild themselves.")
        case .ai: return String(localized: "Stale agent scratch folders, old AI sessions and AI app caches nothing has open.")
        case .large: return String(localized: "The biggest files you haven't changed in a long time.")
        case .apps: return String(localized: "Support files left behind by apps you've already removed.")
        case .photos: return String(localized: "Look-alike shots, screenshots, screen recordings and blurry photos.")
        }
    }

    static func area(for route: Route) -> GuidedArea? { allCases.first { $0.route == route } }
}

/// What the person decided for one suggestion.
enum GuidedDecision: Equatable {
    case undecided, plan, keep
}

/// What happened to one suggestion after the plan ran.
struct GuidedOutcome: Identifiable, Equatable {
    enum Status: Equatable {
        case moved(UUID)
        case skipped(String)
        case failed(String)
        case declined
        case undecided
        case restored
        case restoreFailed(String)
    }

    let suggestion: CleanupSuggestion
    var status: Status
    var id: String { suggestion.id }

    var recordID: UUID? { if case .moved(let id) = status { return id } else { return nil } }
}

/// A past Guided Cleanup run, kept for the history list.
struct GuidedRunRecord: Codable, Identifiable, Equatable {
    var id = UUID()
    var date: Date
    var moved: Int
    var skipped: Int
    var failed: Int
    var declined: Int
    var bytes: Int64
    var areas: [String]
}

/// Approval-first cleanup: audit (read-only) → review → confirm an exact plan → run only that plan → results with undo.
@MainActor @Observable
final class GuidedModel {
    enum Stage: Int, Comparable {
        case areas, auditing, review, running, results
        static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    enum SortOrder: String, CaseIterable, Identifiable {
        case impact = "Largest first"
        case confidence = "Most confident first"
        case age = "Oldest first"
        var id: String { rawValue }
    }

    enum Filter: Hashable {
        case all, plan, area(GuidedArea)
    }

    var stage: Stage = .areas
    var enabled: Set<GuidedArea> {
        didSet { UserDefaults.standard.set(enabled.map(\.rawValue), forKey: Self.areasKey) }
    }
    private(set) var auditedAreas: [GuidedArea] = []
    private(set) var failedAreas: Set<GuidedArea> = []
    private(set) var suggestions: [CleanupSuggestion] = []
    private(set) var decisions: [String: GuidedDecision] = [:]
    private(set) var auditDate: Date?
    private(set) var outcomes: [GuidedOutcome] = []
    private(set) var history: [GuidedRunRecord] = []
    private(set) var isUndoing = false

    var filter: Filter = .all
    var sort: SortOrder = .impact
    var showConfirm = false
    var showAssistant = false

    let assistant = GuidedAssistant()

    private var auditTask: Task<Void, Never>?
    private static let areasKey = "guidedAreas"
    private var historyURL: URL { SharedPaths.support.appendingPathComponent("guided-history.json") }

    init() {
        if let saved = UserDefaults.standard.stringArray(forKey: Self.areasKey) {
            enabled = Set(saved.compactMap(GuidedArea.init(rawValue:)))
        } else {
            enabled = Set(GuidedArea.allCases)
        }
        loadHistory()
    }

    // MARK: Audit

    func tool(for area: GuidedArea) -> (any ScanTool)? { AppModel.shared.tool(for: area.route) }

    func startAudit() {
        guard !enabled.isEmpty, stage != .auditing else { return }
        auditedAreas = GuidedArea.allCases.filter { enabled.contains($0) }
        failedAreas = []
        suggestions = []
        decisions = [:]
        outcomes = []
        filter = .all
        assistant.reset()
        stage = .auditing
        auditTask = Task { await runAudit() }
    }

    private func runAudit() async {
        let tools: [(GuidedArea, any ScanTool)] = auditedAreas.compactMap { area in tool(for: area).map { (area, $0) } }
        await withTaskGroup(of: Void.self) { group in
            for (_, tool) in tools {
                group.addTask { @MainActor in await tool.scan() }
            }
        }
        guard !Task.isCancelled, stage == .auditing else { return }

        var gathered: [CleanupSuggestion] = []
        var seen = Set<String>()
        for (area, tool) in tools {
            if case .failed = tool.phase { failedAreas.insert(area) }
            for s in tool.suggestions() where seen.insert(s.url.standardizedFileURL.path).inserted {
                gathered.append(s)
            }
        }
        suggestions = Self.removingNested(gathered)
        auditDate = .now
        stage = .review
    }

    /// Drops suggestions that sit inside another suggested folder, so nothing is counted or moved twice.
    private static func removingNested(_ list: [CleanupSuggestion]) -> [CleanupSuggestion] {
        let folders = list.filter { FS.isDirectory($0.url) }.map { $0.url.standardizedFileURL.path + "/" }
        guard !folders.isEmpty else { return list }
        return list.filter { s in
            let path = s.url.standardizedFileURL.path
            return !folders.contains { path.hasPrefix($0) }
        }
    }

    /// Stops the audit without moving or changing anything.
    func cancelAudit() {
        auditTask?.cancel()
        for area in auditedAreas { tool(for: area)?.cancelScan() }
        stage = .areas
    }

    /// Leaves the review without carrying anything out.
    func finishWithoutChanges() {
        suggestions = []
        decisions = [:]
        stage = .areas
    }

    // MARK: Review

    func decision(for s: CleanupSuggestion) -> GuidedDecision { decisions[s.id] ?? .undecided }

    func setDecision(_ d: GuidedDecision, for s: CleanupSuggestion) {
        decisions[s.id] = d == .undecided ? nil : d
    }

    func setDecision(_ d: GuidedDecision, forID id: String) {
        guard suggestions.contains(where: { $0.id == id }) else { return }
        decisions[id] = d == .undecided ? nil : d
    }

    func suggestion(withID id: String) -> CleanupSuggestion? { suggestions.first { $0.id == id } }

    func matches(_ s: CleanupSuggestion, _ f: Filter) -> Bool {
        switch f {
        case .all: return true
        case .plan: return decision(for: s) == .plan
        case .area(let a): return s.tool == a.route
        }
    }

    func count(for f: Filter) -> Int { suggestions.filter { matches($0, f) }.count }

    var filterOptions: [Filter] {
        let present = GuidedArea.allCases.filter { a in suggestions.contains { $0.tool == a.route } }
        return [.all, .plan] + present.map { .area($0) }
    }

    func label(for f: Filter) -> String {
        switch f {
        case .all: return "All"
        case .plan: return "In plan"
        case .area(let a): return a.title
        }
    }

    var visible: [CleanupSuggestion] {
        let list = suggestions.filter { matches($0, filter) }
        switch sort {
        case .impact:
            return list.sorted { $0.bytes > $1.bytes }
        case .confidence:
            return list.sorted { $0.confidence != $1.confidence ? $0.confidence > $1.confidence : $0.bytes > $1.bytes }
        case .age:
            return list.sorted { ($0.modified ?? .distantFuture) < ($1.modified ?? .distantFuture) }
        }
    }

    var planned: [CleanupSuggestion] { suggestions.filter { decision(for: $0) == .plan } }
    var plannedBytes: Int64 { planned.reduce(0) { $0 + $1.bytes } }
    var totalBytes: Int64 { suggestions.reduce(0) { $0 + $1.bytes } }
    var undecidedCount: Int { suggestions.filter { decision(for: $0) == .undecided }.count }

    /// Adds every undecided suggestion in the current filter to the plan. Nothing is carried out yet.
    func addAllVisible() {
        for s in visible where decision(for: s) == .undecided { decisions[s.id] = .plan }
    }

    /// Removes every suggestion from the plan. Decisions to leave items unchanged are kept.
    func removeAllFromPlan() {
        for (id, d) in decisions where d == .plan { decisions[id] = nil }
    }

    // MARK: Run

    /// Carries out only the confirmed plan. Each item is re-checked first and skipped if it changed since the audit.
    func execute() async {
        let plan = planned
        guard !plan.isEmpty, stage == .review else { return }
        showConfirm = false
        stage = .running

        let checks: [(CleanupSuggestion, String?)] = await Task.detached(priority: .userInitiated) {
            plan.map { ($0, GuidedVerifier.problem(with: $0)) }
        }.value

        var statuses: [String: GuidedOutcome.Status] = [:]
        var ready: [CleanupSuggestion] = []
        for (s, problem) in checks {
            if let problem { statuses[s.id] = .skipped(problem) } else { ready.append(s) }
        }

        let batch = await TrashLog.shared.moveToTrash(ready.map { (url: $0.url, bytes: $0.bytes) }, tool: .guided)
        var movedByPath: [String: UUID] = [:]
        for r in batch.moved where movedByPath[r.originalPath] == nil { movedByPath[r.originalPath] = r.id }
        var failedByPath: [String: String] = [:]
        for f in batch.failed where failedByPath[f.url.path] == nil { failedByPath[f.url.path] = f.reason }
        for s in ready {
            if let id = movedByPath[s.url.path] {
                statuses[s.id] = .moved(id)
            } else {
                statuses[s.id] = .failed(failedByPath[s.url.path] ?? "macOS didn't confirm that it reached the Trash.")
            }
        }

        outcomes = suggestions.map { s in
            GuidedOutcome(suggestion: s, status: statuses[s.id] ?? (decision(for: s) == .keep ? .declined : .undecided))
        }

        let record = GuidedRunRecord(date: .now,
                                     moved: count(where: { if case .moved = $0 { return true }; return false }),
                                     skipped: count(where: { if case .skipped = $0 { return true }; return false }),
                                     failed: count(where: { if case .failed = $0 { return true }; return false }),
                                     declined: count(where: { $0 == .declined || $0 == .undecided }),
                                     bytes: batch.bytes,
                                     areas: auditedAreas.map(\.rawValue))
        history.insert(record, at: 0)
        saveHistory()

        AppModel.shared.didTrash(paths: batch.movedPaths)
        stage = .results
    }

    private func count(where test: (GuidedOutcome.Status) -> Bool) -> Int { outcomes.filter { test($0.status) }.count }

    func outcomes(where test: (GuidedOutcome.Status) -> Bool) -> [GuidedOutcome] { outcomes.filter { test($0.status) } }

    var movedOutcomes: [GuidedOutcome] {
        outcomes.filter {
            switch $0.status {
            case .moved, .restored, .restoreFailed: return true
            default: return false
            }
        }
    }

    var movedBytes: Int64 { outcomes.filter { $0.recordID != nil }.reduce(0) { $0 + $1.suggestion.bytes } }
    var canUndoAny: Bool { outcomes.contains { $0.recordID != nil } }

    // MARK: Undo

    func undo(_ outcome: GuidedOutcome) async {
        guard let recordID = outcome.recordID, let i = outcomes.firstIndex(where: { $0.id == outcome.id }) else { return }
        isUndoing = true
        let result = await TrashLog.shared.restore([recordID])
        outcomes[i].status = result.restored == 1 ? .restored : .restoreFailed(result.failures.first ?? "It couldn't be restored.")
        isUndoing = false
        AppModel.shared.refreshVolume()
        AppModel.shared.writeSnapshot()
    }

    func undoAll() async {
        isUndoing = true
        for outcome in outcomes where outcome.recordID != nil {
            guard let recordID = outcome.recordID, let i = outcomes.firstIndex(where: { $0.id == outcome.id }) else { continue }
            let result = await TrashLog.shared.restore([recordID])
            outcomes[i].status = result.restored == 1 ? .restored : .restoreFailed(result.failures.first ?? "It couldn't be restored.")
        }
        isUndoing = false
        AppModel.shared.refreshVolume()
        AppModel.shared.writeSnapshot()
    }

    /// Clears the finished run and returns to area selection.
    func startOver() {
        outcomes = []
        suggestions = []
        decisions = [:]
        assistant.reset()
        stage = .areas
    }

    // MARK: History

    func clearHistory() {
        history = []
        saveHistory()
    }

    private func loadHistory() {
        guard let data = try? Data(contentsOf: historyURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        history = (try? decoder.decode([GuidedRunRecord].self, from: data)) ?? []
    }

    private func saveHistory() {
        try? FileManager.default.createDirectory(at: SharedPaths.support, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(Array(history.prefix(50))) {
            try? data.write(to: historyURL, options: .atomic)
        }
    }
}

/// Re-checks a suggestion right before it runs. Synchronous; call off the main thread.
enum GuidedVerifier {
    private static let keys: Set<URLResourceKey> = [
        .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey,
        .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey,
    ]

    private static var protectedPaths: Set<String> {
        let h = FS.home.path
        return ["/", "/Applications", "/System", "/Library", "/Users", "/private", "/usr", "/bin", "/sbin", "/opt",
                h, h + "/Library", h + "/Desktop", h + "/Documents", h + "/Downloads", h + "/Pictures",
                h + "/Movies", h + "/Music", h + "/Applications", h + "/Library/Caches", h + "/Library/Application Support"]
    }

    /// A reason to skip the item, or nil when it is still exactly what the audit found.
    static func problem(with s: CleanupSuggestion) -> String? {
        let url = s.url.standardizedFileURL
        let path = url.path
        if protectedPaths.contains(path) || path.hasPrefix("/System/") {
            return "Reclaim will not move this protected item."
        }
        guard let v = try? url.resourceValues(forKeys: keys) else {
            return "It is no longer where it was during the audit, so there was nothing to move."
        }
        if v.isSymbolicLink == true { return nil }
        if v.isDirectory == true {
            // Folder contents (caches, logs) change constantly; that it still exists as a folder is what matters.
            return nil
        }
        guard v.isRegularFile == true else {
            return "This is no longer a regular file, so Reclaim left it alone."
        }
        if let then = s.modified, let now = v.contentModificationDate, abs(now.timeIntervalSince(then)) > 1 {
            return "This file was modified after the audit, so Reclaim left it alone."
        }
        if s.bytes > 0 {
            let allocated = FS.allocated(v)
            let logical = Int64(v.fileSize ?? 0)
            let tolerance = max(Int64(16_384), s.bytes / 100)
            if abs(allocated - s.bytes) > tolerance && abs(logical - s.bytes) > tolerance {
                return "This file changed size since the audit (\(Fmt.bytes(s.bytes)) → \(Fmt.bytes(allocated))), so Reclaim left it alone."
            }
        }
        return nil
    }
}
