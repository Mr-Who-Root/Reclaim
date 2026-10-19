import SwiftUI
import AppKit

@MainActor @Observable
final class AppsModel: ScanTool {
    enum Mode: String, CaseIterable, Identifiable {
        case uninstall = "Uninstall"
        case leftovers = "Leftovers"
        var id: String { rawValue }
    }

    enum AppSort: String, CaseIterable, Identifiable {
        case name = "Name", size = "Size"
        var id: String { rawValue }
    }

    let route: Route = .apps
    var mode: Mode = .uninstall

    // Installed apps
    private(set) var apps: [InstalledApp] = []
    private(set) var appSizes: [String: Int64] = [:]
    private(set) var appsLoading = false
    private(set) var runningBundleIDs: Set<String> = []
    var appSearch = ""
    var appSort: AppSort = .name

    // Uninstall
    var selectedAppID: String? {
        didSet { if selectedAppID != oldValue { loadSupportFiles() } }
    }
    private(set) var supportItems: [AppSupportItem] = []
    private(set) var supportLoading = false
    var uninstallSelection: Set<String> = []
    private(set) var isWorking = false
    private(set) var quitFailed = false

    // Leftovers (the ScanTool part)
    var phase: ScanPhase = .idle
    private(set) var leftovers: [LeftoverGroup] = []
    var leftoverSelection: Set<String> = []

    private var leftoverTask: Task<[LeftoverGroup], Never>?
    private var sizeTask: Task<Void, Never>?
    private var supportTask: Task<Void, Never>?

    // MARK: ScanTool

    var reclaimableBytes: Int64 { leftovers.reduce(0) { $0 + $1.size } }
    var itemCount: Int { leftovers.count }

    func scan() async {
        await loadApps()
        await scanLeftovers()
    }

    func cancelScan() {
        leftoverTask?.cancel()
    }

    func suggestions() -> [CleanupSuggestion] {
        let items = leftovers.flatMap { group in group.items.map { (group, $0) } }
            .sorted { $0.1.entry.size > $1.1.entry.size }
            .prefix(25)
        return items.map { group, item in
            CleanupSuggestion(
                tool: .apps,
                title: "App leftover: \(item.entry.name)",
                reason: "Support files for \(group.bundleID); no app with this identifier is installed.",
                evidence: [item.location, Fmt.bytes(item.entry.size), "Last changed \(Fmt.age(item.entry.modified)) ago"],
                url: item.entry.url,
                bytes: item.entry.size,
                modified: item.entry.modified,
                confidence: .medium)
        }
    }

    // MARK: Installed apps

    var visibleApps: [InstalledApp] {
        let query = appSearch.trimmingCharacters(in: .whitespaces)
        var list = apps
        if !query.isEmpty {
            list = list.filter {
                $0.name.localizedCaseInsensitiveContains(query) || ($0.bundleID?.localizedCaseInsensitiveContains(query) ?? false)
            }
        }
        if appSort == .size {
            list.sort { (appSizes[$0.id] ?? -1) > (appSizes[$1.id] ?? -1) }
        }
        return list
    }

    var selectedApp: InstalledApp? { apps.first { $0.id == selectedAppID } }

    func isRunning(_ app: InstalledApp) -> Bool {
        if let bid = app.bundleID?.lowercased(), runningBundleIDs.contains(bid) { return true }
        return NSWorkspace.shared.runningApplications.contains { $0.bundleURL?.standardizedFileURL.path == app.url.standardizedFileURL.path }
    }

    func refreshRunning() {
        runningBundleIDs = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier?.lowercased() })
    }

    private var appsLoadTask: Task<Void, Never>?

    /// Loads the app list; concurrent callers wait for the same load.
    func loadApps() async {
        if let existing = appsLoadTask {
            await existing.value
            return
        }
        let task = Task { await self.performLoadApps() }
        appsLoadTask = task
        await task.value
        appsLoadTask = nil
    }

    private func performLoadApps() async {
        appsLoading = true
        refreshRunning()
        let list = await Task.detached(priority: .userInitiated) { AppsScanner.listApps() }.value
        apps = list
        appsLoading = false
        if let id = selectedAppID, !list.contains(where: { $0.id == id }) { selectedAppID = nil }
        measureSizes()
    }

    /// Measures app sizes in the background, publishing them in small batches.
    private func measureSizes() {
        sizeTask?.cancel()
        let pending = apps.filter { appSizes[$0.id] == nil }
        guard !pending.isEmpty else { return }
        sizeTask = Task.detached(priority: .utility) { [weak self] in
            var batch: [String: Int64] = [:]
            for app in pending {
                if Task.isCancelled { return }
                batch[app.id] = FS.allocatedSize(of: app.url)
                if batch.count >= 4 {
                    let done = batch
                    batch.removeAll()
                    await MainActor.run { self?.appSizes.merge(done) { $1 } }
                }
            }
            let done = batch
            await MainActor.run { self?.appSizes.merge(done) { $1 } }
        }
    }

    // MARK: Uninstall

    private func loadSupportFiles() {
        supportTask?.cancel()
        supportItems = []
        uninstallSelection = []
        quitFailed = false
        guard let app = selectedApp else { supportLoading = false; return }
        supportLoading = true
        supportTask = Task { [weak self] in
            let items = await Task.detached(priority: .userInitiated) { AppsScanner.supportFiles(for: app) }.value
            guard let self, !Task.isCancelled, self.selectedAppID == app.id else { return }
            self.supportItems = items
            // The app and exact identifier matches start selected; name-only matches don't.
            self.uninstallSelection = Set(items.filter { !$0.byName }.map(\.id))
            if let appItem = items.first(where: \.isAppBundle) { self.appSizes[app.id] = appItem.entry.size }
            self.supportLoading = false
        }
    }

    var selectedSupportItems: [AppSupportItem] { supportItems.filter { uninstallSelection.contains($0.id) } }
    var uninstallBytes: Int64 { selectedSupportItems.reduce(0) { $0 + $1.entry.size } }

    func toggleSupport(_ item: AppSupportItem) {
        if uninstallSelection.contains(item.id) { uninstallSelection.remove(item.id) } else { uninstallSelection.insert(item.id) }
    }

    /// Asks the app to quit, then waits a few seconds for it to go.
    func quit(_ app: InstalledApp, force: Bool = false) async {
        quitFailed = false
        let running = NSWorkspace.shared.runningApplications.filter {
            ($0.bundleIdentifier != nil && $0.bundleIdentifier?.lowercased() == app.bundleID?.lowercased())
                || $0.bundleURL?.standardizedFileURL.path == app.url.standardizedFileURL.path
        }
        for r in running { _ = force ? r.forceTerminate() : r.terminate() }
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(250))
            refreshRunning()
            if !isRunning(app) { return }
        }
        quitFailed = true
    }

    func uninstall() async {
        guard let app = selectedApp, !isWorking else { return }
        let chosen = selectedSupportItems
        guard !chosen.isEmpty else { return }
        let includesApp = chosen.contains(where: \.isAppBundle)
        if includesApp, isRunning(app) {
            AppModel.shared.showToast(Toast(message: "Quit \(app.name) first",
                                            detail: "Reclaim won't remove an app while it's running.", isError: true))
            return
        }
        isWorking = true
        defer { isWorking = false }

        let moved = await AppModel.shared.trash(chosen.map(\.entry), from: .apps)
        var appGone = moved.contains(app.url.path)

        // Root-owned apps (App Store, some installers) need Finder and an administrator password.
        if includesApp, !appGone, FS.exists(app.url) {
            let url = app.url
            let error = await Task.detached(priority: .userInitiated) { AppsScanner.trashWithFinder(url) }.value
            appGone = !FS.exists(app.url)
            var toast = AppModel.shared.toast ?? Toast(message: "")
            if appGone {
                let supportCount = moved.count
                // Finder doesn't report where it put the app; it lands in ~/.Trash under its own name unless that's taken.
                let trashed = FS.home.appendingPathComponent(".Trash", isDirectory: true).appendingPathComponent(url.lastPathComponent)
                let bytes = chosen.first(where: \.isAppBundle)?.entry.size ?? appSizes[app.id] ?? 0
                toast.undoIDs.append(TrashLog.shared.record(original: url, trashed: trashed, bytes: bytes, tool: .apps))
                toast.message = "Uninstalled \(app.name)"
                toast.detail = "Finder moved the app to the Trash"
                    + (supportCount > 0 ? " along with \(Fmt.count(supportCount, "support item"))." : ".")
                toast.isError = false
                AppModel.shared.didTrash(paths: [url.path])
            } else {
                toast.message = "\(app.name) wasn't removed"
                toast.detail = error ?? "Finder didn't move it to the Trash."
                toast.isError = true
            }
            AppModel.shared.showToast(toast)
        }

        supportItems.removeAll { moved.contains($0.id) || ($0.isAppBundle && appGone) }
        uninstallSelection.subtract(moved)
        if appGone {
            apps.removeAll { $0.id == app.id }
            appSizes[app.id] = nil
            selectedAppID = nil
        }
    }

    // MARK: Leftovers

    var selectedLeftoverItems: [AppSupportItem] {
        leftovers.flatMap(\.items).filter { leftoverSelection.contains($0.id) }
    }
    var leftoverSelectedBytes: Int64 { selectedLeftoverItems.reduce(0) { $0 + $1.entry.size } }

    func toggleLeftover(_ item: AppSupportItem) {
        if leftoverSelection.contains(item.id) { leftoverSelection.remove(item.id) } else { leftoverSelection.insert(item.id) }
    }

    func isGroupSelected(_ group: LeftoverGroup) -> Bool {
        group.items.allSatisfy { leftoverSelection.contains($0.id) }
    }

    func setGroup(_ group: LeftoverGroup, selected: Bool) {
        let ids = group.items.map(\.id)
        if selected { leftoverSelection.formUnion(ids) } else { leftoverSelection.subtract(ids) }
    }

    func scanLeftovers() async {
        leftoverTask?.cancel()
        phase = .scanning("Looking through your Library…")
        refreshRunning()
        var installed = Set(apps.compactMap { $0.bundleID?.lowercased() })
        installed.formUnion(runningBundleIDs)
        let reporter = ProgressReporter { [weak self] message in
            guard let self, self.phase.isScanning else { return }
            self.phase = .scanning(message)
        }
        let task = Task.detached(priority: .userInitiated) {
            AppsScanner.findLeftovers(installed: installed, reporter: reporter)
        }
        leftoverTask = task
        let groups = await task.value
        guard leftoverTask == task else { return }
        if task.isCancelled {
            phase = leftovers.isEmpty ? .idle : .done(.now)
            return
        }
        leftovers = groups
        let valid = Set(groups.flatMap(\.items).map(\.id))
        leftoverSelection.formIntersection(valid)
        phase = .done(.now)
    }

    func forget(paths: Set<String>) {
        leftovers = leftovers.compactMap { group in
            var g = group
            g.items.removeAll { paths.containsPathOrAncestor(of: $0.id) }
            return g.items.isEmpty ? nil : g
        }
        leftoverSelection = leftoverSelection.filter { !paths.containsPathOrAncestor(of: $0) }
        supportItems.removeAll { paths.containsPathOrAncestor(of: $0.id) }
        uninstallSelection = uninstallSelection.filter { !paths.containsPathOrAncestor(of: $0) }
    }

    func trashLeftovers() async {
        let chosen = selectedLeftoverItems
        guard !chosen.isEmpty, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        let moved = await AppModel.shared.trash(chosen.map(\.entry), from: .apps)
        leftovers = leftovers.compactMap { group in
            var g = group
            g.items.removeAll { moved.contains($0.id) }
            return g.items.isEmpty ? nil : g
        }
        leftoverSelection.subtract(moved)
    }
}
