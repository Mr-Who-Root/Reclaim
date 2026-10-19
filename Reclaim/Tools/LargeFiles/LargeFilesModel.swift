import SwiftUI

/// A large file with values the table can sort by.
struct LargeItem: Identifiable, Hashable {
    let entry: FileEntry
    let kind: FS.Kind

    var id: String { entry.id }
    var name: String { entry.name }
    var size: Int64 { entry.size }
    var modifiedSort: Date { entry.modified ?? .distantPast }
    var kindName: String { kind.rawValue }
    var location: String { entry.parentDisplayPath }
    var ageDays: Int { entry.modified?.daysAgo ?? 0 }
}

enum LargeMinSize: Int64, CaseIterable, Identifiable {
    case mb10 = 10_000_000, mb50 = 50_000_000, mb100 = 100_000_000, mb500 = 500_000_000,
         gb1 = 1_000_000_000, gb5 = 5_000_000_000
    var id: Int64 { rawValue }
    var label: String { "≥ \(Fmt.bytes(rawValue))" }
}

enum LargeAge: Int, CaseIterable, Identifiable {
    case any = 0, months3 = 90, months6 = 180, year1 = 365, years2 = 730
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .any: return "Any age"
        case .months3: return "Older than 3 months"
        case .months6: return "Older than 6 months"
        case .year1: return "Older than 1 year"
        case .years2: return "Older than 2 years"
        }
    }
}

enum LargeViewMode: String, CaseIterable, Identifiable {
    case list = "List", table = "Table"
    var id: String { rawValue }
    var icon: String { self == .list ? "list.bullet" : "tablecells" }
}

/// Finds big files you may have forgotten, with size, age and kind filters.
@MainActor @Observable
final class LargeFilesModel: ScanTool {
    let route: Route = .large
    var phase: ScanPhase = .idle

    /// Files of at least 10 MB from the last scan.
    private(set) var items: [LargeItem] = []
    var selection: Set<String> = []
    var scope: ScanScope = .defaults
    var minSize: LargeMinSize = .mb100
    var age: LargeAge = .any
    var kind: FS.Kind? = nil
    var search = ""
    var viewMode: LargeViewMode = .list
    var sortOrder: [KeyPathComparator<LargeItem>] = [KeyPathComparator(\LargeItem.size, order: .reverse)]
    private(set) var isTrashing = false
    private(set) var scannedFileCount = 0

    static let defaultRoots = [FS.downloads, FS.movies, FS.documents, FS.desktop]
    static let defaultsLabel = "Downloads, Movies, Documents & Desktop"

    private var work: Task<LargeScanResult, Never>?
    private var lastScan: Date?

    // MARK: ScanTool

    /// Files of 100 MB or more that haven't changed in six months.
    private var staleBig: [LargeItem] { items.filter { $0.size >= 100_000_000 && $0.ageDays > 180 } }
    /// Every file of 100 MB or more is worth a look here (this tool is left out of the overall total, so nothing is double counted).
    private var big: [LargeItem] { items.filter { $0.size >= 100_000_000 } }
    var reclaimableBytes: Int64 { big.reduce(0) { $0 + $1.size } }
    var itemCount: Int { big.count }

    func scan() async {
        work?.cancel()
        phase = .scanning("Starting…")
        let reporter = ProgressReporter { [weak self] message in
            guard let self, self.phase.isScanning else { return }
            self.phase = .scanning(message)
        }
        let roots = scope.roots(defaults: Self.defaultRoots)
        let task = Task.detached(priority: .userInitiated) {
            LargeFilesScanner.run(roots: roots, reporter: reporter)
        }
        work = task
        let result = await task.value
        guard work == task else { return }
        work = nil
        if task.isCancelled {
            phase = lastScan.map { .done($0) } ?? .idle
            return
        }
        items = result.items
        scannedFileCount = result.scanned
        selection = selection.filter { id in items.contains { $0.id == id } }
        lastScan = .now
        phase = .done(.now)
    }

    func cancelScan() { work?.cancel() }

    func suggestions() -> [CleanupSuggestion] {
        staleBig.sorted { $0.size > $1.size }.prefix(25).map { item in
            let e = item.entry
            let folder = e.url.deletingLastPathComponent().lastPathComponent
            return CleanupSuggestion(
                tool: .large,
                title: "Large older file: \(e.name)",
                reason: "One of the largest files in \(folder), and it hasn't changed in \(Fmt.age(e.modified)). Keep it if you still need it; otherwise it's a big win.",
                evidence: [Fmt.bytes(e.size), "Last changed \(Fmt.date(e.modified))", item.kind.rawValue, e.parentDisplayPath],
                url: e.url, bytes: e.size, modified: e.modified,
                confidence: item.ageDays > 365 ? .medium : .lower)
        }
    }

    // MARK: Filtering

    /// Items passing size, age and search filters, before the kind filter (used for chip counts).
    private var baseFiltered: [LargeItem] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return items.filter { item in
            item.size >= minSize.rawValue
                && (age == .any || item.ageDays > age.rawValue)
                && (query.isEmpty || item.name.localizedCaseInsensitiveContains(query) || item.location.localizedCaseInsensitiveContains(query))
        }
    }

    var visibleItems: [LargeItem] {
        let filtered = baseFiltered.filter { kind == nil || $0.kind == kind }
        return filtered.sorted(using: sortOrder)
    }

    /// Kinds present in the current results, for the chip row.
    var kindOptions: [FS.Kind?] {
        let present = Set(items.map(\.kind))
        return [nil] + FS.Kind.allCases.filter { present.contains($0) }
    }

    func count(for kind: FS.Kind?) -> Int {
        let base = baseFiltered
        guard let kind else { return base.count }
        return base.filter { $0.kind == kind }.count
    }

    var visibleBytes: Int64 { visibleItems.reduce(0) { $0 + $1.size } }

    var selectedItems: [LargeItem] { items.filter { selection.contains($0.id) } }
    var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.size } }

    func toggle(_ item: LargeItem) {
        if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
    }

    func selectAllVisible() { selection.formUnion(visibleItems.map(\.id)) }
    func selectNone() { selection.removeAll() }

    /// Sorts by a single field for the list mode's sort menu.
    func sortBy(_ comparator: KeyPathComparator<LargeItem>) { sortOrder = [comparator] }

    func forget(paths: Set<String>) {
        items.removeAll { paths.containsPathOrAncestor(of: $0.id) }
        selection = selection.filter { !paths.containsPathOrAncestor(of: $0) }
    }

    func trashSelected() async {
        let chosen = selectedItems
        guard !chosen.isEmpty, !isTrashing else { return }
        isTrashing = true
        defer { isTrashing = false }
        let moved = await AppModel.shared.trash(chosen.map(\.entry), from: .large)
        selection.subtract(moved)
        items.removeAll { moved.contains($0.id) }
    }
}

struct LargeScanResult {
    var items: [LargeItem] = []
    var scanned = 0
}

enum LargeFilesScanner {
    static let floor: Int64 = 10_000_000

    static func run(roots: [URL], reporter: ProgressReporter) -> LargeScanResult {
        var result = LargeScanResult()
        var found: [LargeItem] = []
        // Packages (.app, .photoslibrary…) are skipped by walkFiles, so their contents are never offered.
        FS.walkFiles(roots) { url, values in
            result.scanned += 1
            let size = FS.allocated(values)
            if size >= floor {
                let entry = FileEntry(url: url, size: size, modified: values.contentModificationDate,
                                      created: values.creationDate, isDirectory: false)
                found.append(LargeItem(entry: entry, kind: FS.kind(of: url)))
            }
            reporter.report("Checked \(result.scanned.formatted()) files · found \(found.count) large · \(FS.abbreviate(url.deletingLastPathComponent().path))")
            return true
        }
        result.items = found.sorted { $0.size > $1.size }
        return result
    }
}
