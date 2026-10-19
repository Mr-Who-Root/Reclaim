import SwiftUI
import AppKit

/// One top-level item in ~/Downloads, with why it might be worth removing.
struct DownloadItem: Identifiable, Hashable {
    let entry: FileEntry
    /// When it landed in Downloads.
    let added: Date?
    let kind: FS.Kind
    let isInstaller: Bool
    let isArchive: Bool
    let isIncomplete: Bool

    var id: String { entry.id }

    /// The most recent of "added" and "modified", so a fresh download of an old file isn't called old.
    var lastTouched: Date? {
        switch (entry.modified, added) {
        case let (m?, a?): return max(m, a)
        case let (m?, nil): return m
        case let (nil, a?): return a
        default: return nil
        }
    }

    var ageDays: Int { lastTouched?.daysAgo ?? 0 }
    var isOld: Bool { ageDays > 90 }
    var isLarge: Bool { entry.size > 100_000_000 }
    var isMedia: Bool { kind == .video || kind == .audio || kind == .image }
    var isDocument: Bool { kind == .document }

    /// Picked by "Select suggested" and counted as reclaimable.
    var isSuggested: Bool {
        if isIncomplete { return ageDays > 7 }
        if isInstaller || isArchive { return ageDays > 30 }
        return isLarge && ageDays > 180
    }

    /// Short, plain reason shown under the name.
    var reason: String? {
        let age = Fmt.age(lastTouched)
        if isIncomplete, ageDays > 1 { return "Unfinished download from \(age) ago" }
        if isInstaller, ageDays > 30 {
            return entry.ext == "app"
                ? "App left in Downloads for \(age) — move it to Applications or remove it"
                : "Installer unchanged for \(age) — not needed once the app is installed"
        }
        if isArchive, ageDays > 30 { return "Archive unchanged for \(age) — not needed if you've already opened it" }
        if isLarge, ageDays > 180 { return "Large file unchanged for \(age)" }
        if isOld { return "Unchanged for \(age)" }
        return nil
    }

    var badge: (text: String, color: Color)? {
        if isIncomplete { return ("Unfinished", .orange) }
        if isInstaller { return ("Installer", .blue) }
        if isArchive { return ("Archive", .purple) }
        return nil
    }
}

enum DownloadsFilter: String, CaseIterable, Identifiable {
    case all = "All", installers = "Installers", archives = "Archives", old = "Old", large = "Large",
         media = "Media", documents = "Documents"
    var id: String { rawValue }

    func matches(_ item: DownloadItem) -> Bool {
        switch self {
        case .all: return true
        case .installers: return item.isInstaller || item.isIncomplete
        case .archives: return item.isArchive
        case .old: return item.isOld
        case .large: return item.isLarge
        case .media: return item.isMedia
        case .documents: return item.isDocument
        }
    }
}

enum DownloadsSort: String, CaseIterable, Identifiable {
    case size = "Largest First", oldest = "Oldest First", newest = "Newest First", name = "Name"
    var id: String { rawValue }
}

/// Reviews ~/Downloads for old installers, archives and large stale files.
@MainActor @Observable
final class DownloadsModel: ScanTool {
    let route: Route = .downloads
    var phase: ScanPhase = .idle

    private(set) var items: [DownloadItem] = []
    private(set) var accessDenied = false
    var selection: Set<String> = []
    var filter: DownloadsFilter = .all
    var sort: DownloadsSort = .size
    private(set) var isTrashing = false

    private var work: Task<DownloadsScanResult, Never>?
    private var lastScan: Date?

    // MARK: ScanTool

    var reclaimableBytes: Int64 { items.filter(\.isSuggested).reduce(0) { $0 + $1.entry.size } }
    var itemCount: Int { items.filter(\.isSuggested).count }

    func scan() async {
        work?.cancel()
        phase = .scanning("Opening your Downloads folder…")
        let reporter = ProgressReporter { [weak self] message in
            guard let self, self.phase.isScanning else { return }
            self.phase = .scanning(message)
        }
        let task = Task.detached(priority: .userInitiated) {
            DownloadsScanner.run(reporter: reporter)
        }
        work = task
        let result = await task.value
        guard work == task else { return }
        work = nil
        if task.isCancelled {
            phase = lastScan.map { .done($0) } ?? .idle
            return
        }
        accessDenied = result.accessDenied
        if result.accessDenied {
            items = []
            selection = []
            phase = .failed("Downloads isn't reachable yet.")
            return
        }
        items = result.items
        selection = selection.filter { id in items.contains { $0.id == id } }
        lastScan = .now
        phase = .done(.now)
    }

    func cancelScan() { work?.cancel() }

    func suggestions() -> [CleanupSuggestion] {
        items.filter(\.isSuggested)
            .sorted { $0.entry.size > $1.entry.size }
            .prefix(25)
            .map { item in
                let e = item.entry
                let title: String
                let reason: String
                var confidence: CleanupSuggestion.Confidence = .medium
                if item.isIncomplete {
                    title = "Unfinished download: \(e.name)"
                    reason = "This download never finished and hasn't changed in \(Fmt.age(item.lastTouched)). It can't be opened as it is."
                    confidence = .high
                } else if item.isInstaller {
                    title = "Older installer: \(e.name)"
                    reason = "This installer hasn't changed in \(Fmt.age(item.lastTouched)). Once the app is installed, the installer isn't needed — you can download it again any time."
                    if item.ageDays > 90 { confidence = .high }
                } else if item.isArchive {
                    title = "Old archive: \(e.name)"
                    reason = "This archive hasn't changed in \(Fmt.age(item.lastTouched)). If you've already opened it, the archive itself isn't needed."
                    if item.ageDays > 180 { confidence = .high }
                } else {
                    title = "Large older file: \(e.name)"
                    reason = "One of the largest items in Downloads, and it hasn't changed in \(Fmt.age(item.lastTouched))."
                    confidence = .lower
                }
                return CleanupSuggestion(
                    tool: .downloads, title: title, reason: reason,
                    evidence: [Fmt.bytes(e.size), "Last changed \(Fmt.date(item.lastTouched))", "In ~/Downloads"],
                    url: e.url, bytes: e.size, modified: e.modified, confidence: confidence)
            }
    }

    // MARK: Presentation

    var totalBytes: Int64 { items.reduce(0) { $0 + $1.entry.size } }

    func count(for filter: DownloadsFilter) -> Int { items.filter(filter.matches).count }

    var visibleItems: [DownloadItem] {
        let filtered = items.filter(filter.matches)
        switch sort {
        case .size: return filtered.sorted { $0.entry.size > $1.entry.size }
        case .oldest: return filtered.sorted { ($0.lastTouched ?? .distantPast) < ($1.lastTouched ?? .distantPast) }
        case .newest: return filtered.sorted { ($0.lastTouched ?? .distantPast) > ($1.lastTouched ?? .distantPast) }
        case .name: return filtered.sorted { $0.entry.name.localizedStandardCompare($1.entry.name) == .orderedAscending }
        }
    }

    var selectedItems: [DownloadItem] { items.filter { selection.contains($0.id) } }
    var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.entry.size } }

    func toggle(_ item: DownloadItem) {
        if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
    }

    func selectSuggested() { selection = Set(items.filter(\.isSuggested).map(\.id)) }
    func selectAllVisible() { selection.formUnion(visibleItems.map(\.id)) }
    func selectNone() { selection.removeAll() }

    func trashSelected() async {
        let chosen = selectedItems
        guard !chosen.isEmpty, !isTrashing else { return }
        isTrashing = true
        defer { isTrashing = false }
        let moved = await AppModel.shared.trash(chosen.map(\.entry), from: .downloads)
        selection.subtract(moved)
        items.removeAll { moved.contains($0.id) }
    }
}

struct DownloadsScanResult {
    var items: [DownloadItem] = []
    var accessDenied = false
}

enum DownloadsScanner {
    static let incompleteExtensions: Set<String> = ["crdownload", "download", "part", "partial", "opdownload"]

    static func run(reporter: ProgressReporter) -> DownloadsScanResult {
        let folder = FS.downloads
        guard FS.exists(folder) else { return DownloadsScanResult() }
        guard FS.canList(folder) else { return DownloadsScanResult(accessDenied: true) }

        var result = DownloadsScanResult()
        let children = FS.children(of: folder)
        for (index, url) in children.enumerated() {
            if Task.isCancelled { break }
            reporter.report("Measuring \(url.lastPathComponent) (\(index + 1) of \(children.count))")
            guard let entry = FS.entry(for: url) else { continue }
            let added = (try? url.resourceValues(forKeys: [.addedToDirectoryDateKey]))?.addedToDirectoryDate
            let ext = entry.ext
            let kind = FS.kind(of: url)
            result.items.append(DownloadItem(
                entry: entry,
                added: added,
                kind: kind,
                isInstaller: FS.installerExtensions.contains(ext) || ext == "app",
                isArchive: FS.archiveExtensions.contains(ext) || url.lastPathComponent.lowercased().hasSuffix(".tar.gz"),
                isIncomplete: incompleteExtensions.contains(ext)))
        }
        return result
    }

    /// Privacy & Security › Files and Folders.
    @MainActor
    static func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") {
            NSWorkspace.shared.open(url)
        }
    }
}
