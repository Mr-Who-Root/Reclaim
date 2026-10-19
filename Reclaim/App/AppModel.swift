import SwiftUI
import WidgetKit

/// App-wide state: navigation, every tool's model, Smart Scan, the scheduler and the undo toast.
@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    var route: Route? = .home
    /// Which Settings section the in-app Settings page shows.
    var settingsSection: SettingsSection? = .access
    var toast: Toast?
    var showOnboarding = !UserDefaults.standard.bool(forKey: PrefKey.didOnboard)
    var volume = VolumeStats.startup()

    let junk = JunkModel()
    let aiJunk = AIJunkModel()
    let downloads = DownloadsModel()
    let duplicates = DuplicatesModel()
    let photos = PhotosModel()
    let large = LargeFilesModel()
    let apps = AppsModel()
    let security = SecurityModel()
    let storageMap = StorageMapModel()
    let guided = GuidedModel()
    let trashLog = TrashLog.shared

    // Smart Scan
    private(set) var smartScanRunning = false
    private(set) var scheduledScanRunning = false
    private(set) var lastSmartScan: Date? = UserDefaults.standard.object(forKey: PrefKey.lastSmartScan) as? Date
    private var smartScanTask: Task<Void, Never>?
    private var schedulerTimer: Timer?
    private var toastDismissTask: Task<Void, Never>?

    /// Tools that report reclaimable space, in display order.
    var scanTools: [any ScanTool] { [junk, aiJunk, downloads, duplicates, photos, large, apps] }

    func tool(for route: Route) -> (any ScanTool)? {
        switch route {
        case .junk: return junk
        case .ai: return aiJunk
        case .downloads: return downloads
        case .duplicates: return duplicates
        case .photos: return photos
        case .large: return large
        case .leftovers: return apps
        default: return nil
        }
    }

    /// Reviewable bytes across the cleanup tools. Large & Old is left out because its files
    /// overlap with Downloads and Duplicates and would be counted twice.
    var totalReclaimable: Int64 {
        scanTools.filter { $0.route != .large }.reduce(0) { $0 + $1.reclaimableBytes }
    }

    // MARK: Smart Scan

    /// Runs every cleanup tool (plus Security Check) in one pass. Nothing is removed.
    func startSmartScan(includeSecurity: Bool = true) {
        guard !smartScanRunning else { return }
        smartScanTask = Task { await runSmartScan(includeSecurity: includeSecurity) }
    }

    func runSmartScan(includeSecurity: Bool = true) async {
        guard !smartScanRunning else { return }
        smartScanRunning = true
        defer { smartScanRunning = false }
        await withTaskGroup(of: Void.self) { group in
            for tool in scanTools {
                group.addTask { @MainActor in await tool.scan() }
            }
            if includeSecurity {
                group.addTask { @MainActor in await self.security.scan() }
            }
        }
        lastSmartScan = .now
        UserDefaults.standard.set(lastSmartScan, forKey: PrefKey.lastSmartScan)
        refreshVolume()
        writeSnapshot()
    }

    func cancelSmartScan() {
        smartScanTask?.cancel()
        for tool in scanTools { tool.cancelScan() }
        security.cancelScan()
    }

    // MARK: Trash + undo

    /// Moves entries to the Trash, shows the undo toast and returns the paths that actually moved.
    @discardableResult
    func trash(_ entries: [FileEntry], from tool: Route) async -> Set<String> {
        await trash(entries.map { (url: $0.url, bytes: $0.size) }, from: tool)
    }

    @discardableResult
    func trash(_ items: [(url: URL, bytes: Int64)], from tool: Route) async -> Set<String> {
        guard !items.isEmpty else { return [] }
        let batch = await trashLog.moveToTrash(items, tool: tool)
        var detail: String?
        if !batch.failed.isEmpty {
            let first = batch.failed.prefix(2).map { "\($0.url.lastPathComponent): \($0.reason)" }.joined(separator: "\n")
            detail = "\(Fmt.count(batch.failed.count, "item")) couldn't be moved and were left unchanged.\n\(first)"
        }
        if batch.moved.isEmpty {
            showToast(Toast(message: "Nothing was moved to the Trash", detail: detail, isError: true))
        } else {
            showToast(Toast(message: "Moved \(Fmt.count(batch.moved.count, "item")) (\(Fmt.bytes(batch.bytes))) to the Trash",
                            detail: detail, undoIDs: batch.moved.map(\.id), isError: !batch.failed.isEmpty))
        }
        didTrash(paths: batch.movedPaths)
        return batch.movedPaths
    }

    /// Tells every tool that these paths are gone, then refreshes free space and the widget.
    func didTrash(paths: Set<String>) {
        if !paths.isEmpty {
            for tool in scanTools { tool.forget(paths: paths) }
        }
        refreshVolume()
        writeSnapshot()
    }

    func undo(_ toast: Toast) async {
        let result = await trashLog.restore(toast.undoIDs)
        if result.failures.isEmpty {
            showToast(Toast(message: "Restored \(Fmt.count(result.restored, "item")) to their original folders",
                            detail: "Scan again to see them in the results."))
        } else {
            showToast(Toast(message: "Restored \(result.restored) of \(toast.undoIDs.count) items",
                            detail: result.failures.prefix(2).joined(separator: "\n"), isError: true))
        }
        refreshVolume()
    }

    func showToast(_ toast: Toast) {
        self.toast = toast
        toastDismissTask?.cancel()
        let id = toast.id
        toastDismissTask = Task {
            try? await Task.sleep(for: .seconds(toast.undoIDs.isEmpty ? 5 : 12))
            if self.toast?.id == id { self.toast = nil }
        }
    }

    // MARK: Status

    func refreshVolume() {
        volume = VolumeStats.startup()
        SpaceHistory.shared.record(volume)
    }

    /// True once any tool has scanned (or is scanning) in this session.
    var hasSessionResults: Bool {
        smartScanRunning || scanTools.contains { $0.phase.isDone || $0.phase.isScanning }
    }

    /// Saves what the widget and Shortcuts read.
    func writeSnapshot() {
        var snapshot = ReclaimSnapshot()
        snapshot.lastScan = lastSmartScan
        snapshot.reclaimableBytes = totalReclaimable
        snapshot.accentHex = Accent.current.hex
        snapshot.vividWidget = UserDefaults.standard.object(forKey: PrefKey.vividWidget) as? Bool ?? true
        snapshot.save()
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: URLs

    /// Handles `reclaim://scan`, `reclaim://junk`, `reclaim://guided` and so on.
    func handle(url: URL) {
        guard url.scheme == "reclaim" else { return }
        let target = (url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).lowercased()
        if target == "settings" {
            let sub = url.pathComponents.dropFirst().first ?? ""
            settingsSection = SettingsSection(rawValue: sub) ?? settingsSection
            route = .settings
        } else if target == "scan" || target == "smartscan" {
            route = .home
            startSmartScan()
        } else if let r = Route(rawValue: target) {
            route = r
        }
    }

    // MARK: Scheduler

    func startScheduler() {
        schedulerTimer?.invalidate()
        schedulerTimer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { _ in
            Task { @MainActor in await AppModel.shared.runScheduledScanIfDue() }
        }
        Task {
            try? await Task.sleep(for: .seconds(20))
            await runScheduledScanIfDue()
        }
    }

    func runScheduledScanIfDue() async {
        guard let interval = ScheduleFrequency.activeInterval, !smartScanRunning else { return }
        let last = UserDefaults.standard.object(forKey: PrefKey.lastScheduledScan) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) >= interval else { return }
        scheduledScanRunning = true
        await runSmartScan(includeSecurity: false)
        scheduledScanRunning = false
        UserDefaults.standard.set(Date(), forKey: PrefKey.lastScheduledScan)
        let thresholdGB = UserDefaults.standard.object(forKey: PrefKey.notifyThresholdGB) as? Int ?? 1
        let total = totalReclaimable
        if UserDefaults.standard.bool(forKey: PrefKey.notifyEnabled), total > 0, total >= Int64(thresholdGB) * 1_000_000_000 {
            Notifier.post(title: "\(Fmt.bytes(total)) is ready to review",
                          body: "Your scheduled scan found space to reclaim. Nothing was removed — open Reclaim to review.")
        }
    }
}
