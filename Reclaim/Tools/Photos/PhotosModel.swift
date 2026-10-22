import SwiftUI

enum PhotoCategory: String, CaseIterable, Identifiable {
    case lookalikes, screenshots, recordings, blurry
    var id: String { rawValue }
    var title: String {
        switch self {
        case .lookalikes: return String(localized: "Look-alikes")
        case .screenshots: return String(localized: "Screenshots")
        case .recordings: return String(localized: "Screen Recordings")
        case .blurry: return String(localized: "Blurry")
        }
    }
}

/// Photos that look almost the same, with one suggested keeper.
struct PhotoGroup: Identifiable, Hashable {
    let id: String
    var items: [PhotoItem]
    var keeperPath: String
    var keeper: PhotoItem? { items.first { $0.id == keeperPath } }
    var extras: [PhotoItem] { items.filter { $0.id != keeperPath } }
    var wasted: Int64 { extras.reduce(0) { $0 + $1.entry.size } }
    var date: Date { items.first?.date ?? .distantPast }
}

@MainActor @Observable
final class PhotosModel: ScanTool {
    let route: Route = .photos
    var phase: ScanPhase = .idle

    static let defaultRoots: [URL] = [FS.pictures, FS.desktop, FS.downloads, FS.movies]
    static let defaultsLabel = "Pictures, Desktop, Downloads & Movies"
    /// Screenshots and recordings older than this are suggested.
    static let staleDays = 30

    var scope: ScanScope = .home
    var category: PhotoCategory = .lookalikes
    private(set) var sensitivity: PhotoSensitivity = .normal

    private(set) var photos: [PhotoItem] = []
    private(set) var groups: [PhotoGroup] = []
    private(set) var screenshots: [PhotoItem] = []
    private(set) var recordings: [PhotoItem] = []
    private(set) var blurry: [PhotoItem] = []
    var selected: Set<String> = []
    private(set) var isTrashing = false
    private(set) var lastScan: Date?
    private(set) var scannedScopeLabel = ""

    @ObservationIgnored private var pairs: [PhotoPair] = []
    @ObservationIgnored private var task: Task<PhotoScanResult?, Never>?
    @ObservationIgnored private var scanID = UUID()

    // MARK: Totals

    private func isStale(_ item: PhotoItem) -> Bool { item.date.daysAgo > Self.staleDays }

    /// Everything Photo Clutter suggests: look-alike extras, old screenshots and recordings, blurry shots.
    private var suggestedItems: [PhotoItem] {
        var seen = Set<String>()
        var out: [PhotoItem] = []
        let all = groups.flatMap(\.extras) + screenshots.filter(isStale) + recordings.filter(isStale) + blurry
        for item in all where seen.insert(item.id).inserted { out.append(item) }
        return out
    }

    var reclaimableBytes: Int64 { suggestedItems.reduce(0) { $0 + $1.entry.size } }
    var itemCount: Int { suggestedItems.count }

    func count(for category: PhotoCategory) -> Int {
        switch category {
        case .lookalikes: return groups.reduce(0) { $0 + $1.items.count }
        case .screenshots: return screenshots.count
        case .recordings: return recordings.count
        case .blurry: return blurry.count
        }
    }

    func bytes(for category: PhotoCategory) -> Int64 {
        switch category {
        case .lookalikes: return groups.reduce(0) { $0 + $1.wasted }
        case .screenshots: return screenshots.reduce(0) { $0 + $1.entry.size }
        case .recordings: return recordings.reduce(0) { $0 + $1.entry.size }
        case .blurry: return blurry.reduce(0) { $0 + $1.entry.size }
        }
    }

    /// Every item by path, across categories.
    private var itemsByPath: [String: PhotoItem] {
        var map: [String: PhotoItem] = [:]
        for item in photos + screenshots + recordings { map[item.id] = item }
        return map
    }

    var selectedEntries: [FileEntry] {
        let keepers = Set(groups.map(\.keeperPath))
        let map = itemsByPath
        return selected.subtracting(keepers).compactMap { map[$0]?.entry }
    }
    var selectedBytes: Int64 { selectedEntries.reduce(0) { $0 + $1.size } }
    var selectedCount: Int { selectedEntries.count }

    // MARK: Scan

    func scan() async {
        task?.cancel()
        let id = UUID()
        scanID = id
        let roots = scope.roots(defaults: Self.defaultRoots)
        let label = scope.label(defaultsLabel: Self.defaultsLabel)
        let skipProjects = scope == .home
        phase = .scanning("Looking for photos…")
        let reporter = ProgressReporter { [weak self] message in
            guard let self, self.scanID == id, self.phase.isScanning else { return }
            self.phase = .scanning(message)
        }
        let t = Task.detached(priority: .userInitiated) {
            await PhotoAnalysis.run(roots: roots, skipProjects: skipProjects, progress: reporter)
        }
        task = t
        let result = await t.value
        guard scanID == id else { return }
        task = nil
        guard let result else {
            phase = lastScan.map { .done($0) } ?? .idle
            return
        }
        scannedScopeLabel = label
        photos = result.photos
        pairs = result.pairs
        screenshots = result.screenshots
        recordings = result.recordings
        blurry = result.photos
            .filter { p in
                guard let v = p.sharpness else { return false }
                return v < PhotoAnalysis.blurVariance && min(p.pixelWidth, p.pixelHeight) >= 300
            }
            .sorted { ($0.sharpness ?? 0) < ($1.sharpness ?? 0) }
        selected = []
        groups = []
        regroup(preselect: true)
        lastScan = .now
        dropExcluded()
        phase = .done(.now)
    }

    func cancelScan() {
        task?.cancel()
    }

    func setSensitivity(_ s: PhotoSensitivity) {
        guard s != sensitivity else { return }
        sensitivity = s
        regroup(preselect: true)
    }

    /// Rebuilds look-alike groups for the current sensitivity. Keepers the person picked are kept when
    /// still in a group; with `preselect`, every non-keeper is selected.
    private func regroup(preselect: Bool) {
        let previousKeepers = Set(groups.map(\.keeperPath))
        let oldExtras = Set(groups.flatMap(\.extras).map(\.id))
        let raw = PhotoAnalysis.lookalikeGroups(photos: photos, pairs: pairs, threshold: sensitivity.threshold)
        groups = raw.compactMap { items in
            guard let keeper = items.first(where: { previousKeepers.contains($0.id) }) ?? PhotoAnalysis.bestKeeper(items) else { return nil }
            return PhotoGroup(id: items.map(\.id).sorted().joined(separator: "|"), items: items, keeperPath: keeper.id)
        }
        .sorted { $0.date > $1.date }
        if preselect {
            selected.subtract(oldExtras)
            selected.formUnion(groups.flatMap(\.extras).map(\.id))
        }
        selected.subtract(groups.map(\.keeperPath))
    }

    // MARK: Selection

    var keeperPaths: Set<String> { Set(groups.map(\.keeperPath)) }

    func isKeeper(_ item: PhotoItem) -> Bool { groups.contains { $0.keeperPath == item.id } }

    func toggle(_ item: PhotoItem) {
        guard !isKeeper(item) else { return }
        if selected.contains(item.id) { selected.remove(item.id) } else { selected.insert(item.id) }
    }

    func keep(_ item: PhotoItem, in groupID: String) {
        guard let i = groups.firstIndex(where: { $0.id == groupID }) else { return }
        let old = groups[i].keeperPath
        guard old != item.id else { return }
        let wasSelected = selected.contains(item.id)
        selected.remove(item.id)
        if wasSelected { selected.insert(old) }
        groups[i].keeperPath = item.id
    }

    func items(for category: PhotoCategory) -> [PhotoItem] {
        switch category {
        case .lookalikes: return groups.flatMap(\.extras)
        case .screenshots: return screenshots
        case .recordings: return recordings
        case .blurry: return blurry
        }
    }

    func selectAll(in category: PhotoCategory) {
        selected.formUnion(items(for: category).map(\.id))
        selected.subtract(groups.map(\.keeperPath))
    }

    func selectStale(in category: PhotoCategory) {
        selected.formUnion(items(for: category).filter(isStale).map(\.id))
    }

    func deselectAll(in category: PhotoCategory) {
        let ids = category == .lookalikes ? Set(groups.flatMap(\.items).map(\.id)) : Set(items(for: category).map(\.id))
        selected.subtract(ids)
    }

    // MARK: Trash

    func forget(paths: Set<String>) {
        let gone: (String) -> Bool = { paths.containsPathOrAncestor(of: $0) }
        guard photos.contains(where: { gone($0.id) }) || screenshots.contains(where: { gone($0.id) })
                || recordings.contains(where: { gone($0.id) }) || blurry.contains(where: { gone($0.id) }) else { return }
        selected = selected.filter { !gone($0) }
        photos.removeAll { gone($0.id) }
        screenshots.removeAll { gone($0.id) }
        recordings.removeAll { gone($0.id) }
        blurry.removeAll { gone($0.id) }
        pairs.removeAll { gone($0.a) || gone($0.b) }
        regroup(preselect: false)
    }

    func trashSelected() async {
        let entries = selectedEntries
        guard !entries.isEmpty, !isTrashing else { return }
        isTrashing = true
        defer { isTrashing = false }
        let moved = await AppModel.shared.trash(entries, from: route)
        guard !moved.isEmpty else { return }
        selected.subtract(moved)
        photos.removeAll { moved.contains($0.id) }
        screenshots.removeAll { moved.contains($0.id) }
        recordings.removeAll { moved.contains($0.id) }
        blurry.removeAll { moved.contains($0.id) }
        pairs.removeAll { moved.contains($0.a) || moved.contains($0.b) }
        regroup(preselect: false)
    }

    // MARK: Guided Cleanup

    func suggestions() -> [CleanupSuggestion] {
        var out: [CleanupSuggestion] = []
        for g in groups {
            guard let keeper = g.keeper else { continue }
            for item in g.extras {
                out.append(CleanupSuggestion(
                    tool: .photos,
                    title: "Look-alike photo: \(item.entry.name)",
                    reason: "It looks almost identical to \(Fmt.count(g.items.count - 1, "other photo")) taken around the same time. The best copy, \(keeper.entry.name), stays.",
                    evidence: [Fmt.bytes(item.entry.size), "Taken \(Fmt.dateTime(item.date))", "In \(item.entry.parentDisplayPath)"],
                    url: item.entry.url, bytes: item.entry.size, modified: item.entry.modified, confidence: .medium))
            }
        }
        for item in screenshots where isStale(item) {
            out.append(CleanupSuggestion(
                tool: .photos,
                title: "Old screenshot: \(item.entry.name)",
                reason: "This screenshot is \(Fmt.age(item.date)) old. Screenshots are usually only needed for a short while.",
                evidence: [Fmt.bytes(item.entry.size), "Taken \(Fmt.date(item.date))"],
                url: item.entry.url, bytes: item.entry.size, modified: item.entry.modified, confidence: .medium))
        }
        for item in recordings where isStale(item) {
            out.append(CleanupSuggestion(
                tool: .photos,
                title: "Old screen recording: \(item.entry.name)",
                reason: "This screen recording is \(Fmt.age(item.date)) old, and recordings take a lot of space.",
                evidence: [Fmt.bytes(item.entry.size), "Recorded \(Fmt.date(item.date))"],
                url: item.entry.url, bytes: item.entry.size, modified: item.entry.modified, confidence: .medium))
        }
        for item in blurry {
            out.append(CleanupSuggestion(
                tool: .photos,
                title: "Blurry photo: \(item.entry.name)",
                reason: "It scored \(item.sharpnessScore ?? 0)/100 for sharpness, so it is likely out of focus or shaken. Check it before removing.",
                evidence: [Fmt.bytes(item.entry.size), "Sharpness \(item.sharpnessScore ?? 0)/100"],
                url: item.entry.url, bytes: item.entry.size, modified: item.entry.modified, confidence: .lower))
        }
        var seen = Set<String>()
        return Array(out.sorted { $0.bytes > $1.bytes }.filter { seen.insert($0.url.path).inserted }.prefix(25))
    }
}
