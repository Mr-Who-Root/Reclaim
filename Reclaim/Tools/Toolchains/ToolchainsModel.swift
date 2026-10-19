import Foundation

/// Old SDK and toolchain versions: Android NDKs and platforms, simulator runtimes, extra Xcodes, JDKs and
/// Node/Python/Ruby/Rust/Go versions. Keeps the default, the newest, anything in use and anything a project asks for.
@MainActor @Observable
final class ToolchainsModel: ScanTool {
    let route: Route = .toolchains
    var phase: ScanPhase = .idle
    private(set) var versions: [ToolVersion] = []
    var selection: Set<String> = []
    private(set) var isWorking = false
    private(set) var deletingRuntime: String?
    private var scanGeneration: UUID?

    struct Section: Identifiable {
        let family: ToolFamily
        let versions: [ToolVersion]
        var id: String { family.rawValue }
        var bytes: Int64 { versions.reduce(0) { $0 + $1.bytes } }
        var removableBytes: Int64 { versions.filter(\.isRemovable).reduce(0) { $0 + $1.bytes } }
    }

    var sections: [Section] {
        ToolFamily.allCases.compactMap { family in
            let list = versions.filter { $0.family == family }
            return list.isEmpty ? nil : Section(family: family, versions: list)
        }
    }

    private var recommended: [ToolVersion] { versions.filter { $0.isTrashable && $0.isSafe } }
    var reclaimableBytes: Int64 { recommended.reduce(0) { $0 + $1.bytes } }
    var itemCount: Int { recommended.count }
    var removableBytes: Int64 { versions.filter(\.isRemovable).reduce(0) { $0 + $1.bytes } }
    var totalBytes: Int64 { versions.reduce(0) { $0 + $1.bytes } }
    var selectedBytes: Int64 { versions.filter { selection.contains($0.id) }.reduce(0) { $0 + $1.bytes } }

    func scan() async {
        phase = .scanning(String(localized: "Looking for SDKs and toolchains…"))
        let reporter = ProgressReporter { [weak self] message in
            guard let self, case .scanning = self.phase else { return }
            self.phase = .scanning(message)
        }
        CodeIndex.invalidate()
        let generation = UUID()
        scanGeneration = generation
        let found = await offPool { ToolchainScanner.scan(progress: reporter) }
        guard scanGeneration == generation else { return }
        scanGeneration = nil
        versions = found
        selection = Set(recommended.map(\.id))
        dropExcluded()
        phase = .done(.now)
    }

    func cancelScan() {
        guard scanGeneration != nil else { return }
        scanGeneration = nil
        phase = versions.isEmpty ? .idle : .done(.now)
    }

    func suggestions() -> [CleanupSuggestion] { [] }

    func forget(paths: Set<String>) {
        versions.removeAll { paths.containsPathOrAncestor(of: $0.url.path) }
        selection = selection.filter { id in versions.contains { $0.id == id } }
    }

    func toggle(_ v: ToolVersion) {
        guard v.isTrashable else { return }
        if selection.contains(v.id) { selection.remove(v.id) } else { selection.insert(v.id) }
    }

    func selectAllRemovable() { selection = Set(versions.filter(\.isTrashable).map(\.id)) }
    func selectRecommended() { selection = Set(recommended.map(\.id)) }
    func selectNone() { selection.removeAll() }

    func trashSelected() async {
        let chosen = versions.filter { selection.contains($0.id) && $0.isTrashable }
        guard !chosen.isEmpty, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        var items: [(url: URL, bytes: Int64)] = []
        for v in chosen {
            if case .trash(let extra) = v.removal { items.append((v.url, v.bytes)); items += extra.map { ($0, 0) } }
        }
        var moved = items.isEmpty ? [] : await AppModel.shared.trash(items, from: .toolchains)
        // Root-owned installs (python.org, JDK installers): Finder asks for an administrator password.
        for v in chosen where v.removal == .finder {
            let url = v.url
            let error = await offPool { AppsScanner.trashWithFinder(url) }
            if !FS.exists(url) {
                let trashed = FS.home.appendingPathComponent(".Trash", isDirectory: true).appendingPathComponent(url.lastPathComponent)
                let id = TrashLog.shared.record(original: url, trashed: trashed, bytes: v.bytes, tool: .toolchains)
                moved.insert(url.path)
                AppModel.shared.showToast(Toast(message: String(localized: "Moved \(v.name) to the Trash"),
                                                detail: String(localized: "Finder moved it after asking for your password."), undoIDs: [id]))
                AppModel.shared.didTrash(paths: [url.path])
            } else {
                AppModel.shared.showToast(Toast(message: String(localized: "\(v.name) wasn't removed"),
                                                detail: error ?? String(localized: "Finder didn't move it to the Trash."), isError: true))
            }
        }
        forget(paths: moved)
    }

    /// Deletes a simulator runtime with simctl (it lives in a system disk image, so it can't go to the Trash).
    func deleteRuntime(_ v: ToolVersion) async {
        guard case .simctl(let id) = v.removal, deletingRuntime == nil else { return }
        deletingRuntime = v.id
        let result = await offPool { Shell.run("/usr/bin/xcrun", ["simctl", "runtime", "delete", id], timeout: 300) }
        deletingRuntime = nil
        if result.ok {
            versions.removeAll { $0.id == v.id }
            AppModel.shared.showToast(Toast(message: String(localized: "Deleted \(v.name)"),
                                            detail: String(localized: "Freed \(Fmt.bytes(v.bytes)). Download it again in Xcode › Settings › Components.")))
            AppModel.shared.refreshVolume()
        } else {
            AppModel.shared.showToast(Toast(message: String(localized: "\(v.name) wasn't deleted"),
                                            detail: result.err.isEmpty ? nil : String(result.err.prefix(200)), isError: true))
        }
    }

    /// Opens Uninstall an App with this Xcode selected.
    func uninstall(_ v: ToolVersion) {
        let apps = AppModel.shared.apps
        AppModel.shared.route = .apps
        Task {
            if apps.apps.isEmpty { await apps.loadApps() }
            apps.selectedAppID = v.url.path
        }
    }
}
