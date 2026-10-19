import SwiftUI

@MainActor @Observable
final class DuplicatesModel: ScanTool {
    let route: Route = .duplicates
    var phase: ScanPhase = .idle

    static let defaultRoots: [URL] = [FS.downloads, FS.desktop, FS.documents]
    static let defaultsLabel = "Downloads, Desktop & Documents"

    var scope: ScanScope = .defaults
    var minSize: DupMinSize = .kb100
    private(set) var keepRule: DupKeepRule = .oldest

    private(set) var groups: [DuplicateGroup] = []
    var selected: Set<String> = []
    private(set) var isTrashing = false
    private(set) var stats = DuplicateFinder.Stats()
    private(set) var lastScan: Date?
    /// The scope the current results came from.
    private(set) var scannedScopeLabel = ""

    @ObservationIgnored private var task: Task<DuplicateFinder.Result?, Never>?
    @ObservationIgnored private var scanID = UUID()

    // MARK: Totals

    /// Every copy except the keepers.
    var reclaimableBytes: Int64 { groups.reduce(0) { $0 + $1.wasted } }
    var itemCount: Int { groups.reduce(0) { $0 + $1.files.count - 1 } }

    var selectedEntries: [FileEntry] {
        groups.flatMap { g in g.files.filter { selected.contains($0.path) && $0.path != g.keeperPath } }
    }
    var selectedBytes: Int64 { selectedEntries.reduce(0) { $0 + $1.size } }

    // MARK: Scan

    func scan() async {
        task?.cancel()
        let id = UUID()
        scanID = id
        let roots = scope.roots(defaults: Self.defaultRoots)
        let minBytes = minSize.rawValue
        let label = scope.label(defaultsLabel: Self.defaultsLabel)
        phase = .scanning("Looking through files…")
        let reporter = ProgressReporter { [weak self] message in
            guard let self, self.scanID == id, self.phase.isScanning else { return }
            self.phase = .scanning(message)
        }
        let t = Task.detached(priority: .userInitiated) {
            DuplicateFinder.run(roots: roots, minSize: minBytes, progress: reporter)
        }
        task = t
        let result = await t.value
        guard scanID == id else { return }
        task = nil
        guard let result else {
            phase = lastScan.map { .done($0) } ?? .idle
            return
        }
        stats = result.stats
        scannedScopeLabel = label
        groups = result.groups.compactMap { raw in
            guard let keeper = keepRule.pickKeeper(raw.files) else { return nil }
            return DuplicateGroup(id: raw.hash, fileSize: raw.size, files: raw.files.sorted { $0.path < $1.path }, keeperPath: keeper.path)
        }
        .sorted { ($0.wasted, $0.name) > ($1.wasted, $1.name) }
        selectAllButKeepers()
        lastScan = .now
        phase = .done(.now)
    }

    func cancelScan() {
        task?.cancel()
    }

    // MARK: Selection

    func isKeeper(_ entry: FileEntry, in group: DuplicateGroup) -> Bool { entry.path == group.keeperPath }

    func toggle(_ entry: FileEntry, in group: DuplicateGroup) {
        guard entry.path != group.keeperPath else { return }
        if selected.contains(entry.path) { selected.remove(entry.path) } else { selected.insert(entry.path) }
    }

    /// Makes `entry` the keeper of its group. The old keeper takes over the new keeper's selection state.
    func keep(_ entry: FileEntry, in groupID: String) {
        guard let i = groups.firstIndex(where: { $0.id == groupID }) else { return }
        let old = groups[i].keeperPath
        guard old != entry.path else { return }
        let wasSelected = selected.contains(entry.path)
        selected.remove(entry.path)
        if wasSelected { selected.insert(old) }
        groups[i].keeperPath = entry.path
    }

    /// Re-picks every keeper by `rule` and selects all other copies.
    func apply(_ rule: DupKeepRule) {
        keepRule = rule
        for i in groups.indices {
            if let k = rule.pickKeeper(groups[i].files) { groups[i].keeperPath = k.path }
        }
        selectAllButKeepers()
    }

    func selectAllButKeepers() {
        selected = Set(groups.flatMap { $0.copies.map(\.path) })
    }

    /// Selects every non-keeper copy inside `folder` (recursively).
    func selectCopies(in folder: URL) {
        let prefix = folder.standardizedFileURL.path.hasSuffix("/") ? folder.standardizedFileURL.path : folder.standardizedFileURL.path + "/"
        for g in groups {
            for f in g.copies where f.path.hasPrefix(prefix) { selected.insert(f.path) }
        }
    }

    func chooseFolderAndSelect() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Copies"
        panel.message = "Select every duplicate copy inside this folder. Keepers stay unselected."
        panel.directoryURL = FS.home
        if panel.runModal() == .OK, let url = panel.url { selectCopies(in: url) }
    }

    func clearSelection() { selected.removeAll() }

    // MARK: Trash

    func trashSelected() async {
        let entries = selectedEntries
        guard !entries.isEmpty, !isTrashing else { return }
        isTrashing = true
        defer { isTrashing = false }
        let moved = await AppModel.shared.trash(entries, from: route)
        guard !moved.isEmpty else { return }
        selected.subtract(moved)
        groups = groups.compactMap { group in
            var g = group
            g.files.removeAll { moved.contains($0.path) }
            guard g.files.count > 1 else { return nil }
            if !g.files.contains(where: { $0.path == g.keeperPath }), let k = keepRule.pickKeeper(g.files) {
                g.keeperPath = k.path
            }
            return g
        }
    }

    // MARK: Guided Cleanup

    func suggestions() -> [CleanupSuggestion] {
        var out: [CleanupSuggestion] = []
        for g in groups {
            guard let keeper = g.keeper else { continue }
            for copy in g.copies {
                out.append(CleanupSuggestion(
                    tool: .duplicates,
                    title: "Duplicate copy: \(copy.name)",
                    reason: "Its content matches another copy byte for byte; the keeper at \(keeper.displayPath) stays untouched.",
                    evidence: [Fmt.bytes(copy.size), "\(g.files.count) identical copies", "In \(copy.parentDisplayPath)"],
                    url: copy.url, bytes: copy.size, modified: copy.modified, confidence: .high))
            }
        }
        return Array(out.sorted { $0.bytes > $1.bytes }.prefix(25))
    }
}
