import Foundation

/// Housekeeping that the tools themselves do best: `brew cleanup`, `brew autoremove` and `git gc`.
/// Reclaim reads their dry runs and counts, and runs the command only after you confirm.
@MainActor @Observable
final class MaintenanceModel: ScanTool {
    let route: Route = .maintenance
    var phase: ScanPhase = .idle

    enum Action: Equatable { case brewCleanup, brewAutoremove, gc(String), gcAll }

    private(set) var brewInstalled = false
    private(set) var brewItems: [BrewItem] = []
    private(set) var brewUnused: [BrewItem] = []
    private(set) var repos: [GitRepoStatus] = []
    private(set) var healthyRepoCount = 0
    private(set) var running: Action?
    private var scanGeneration: UUID?

    var brewBytes: Int64 { brewItems.reduce(0) { $0 + $1.bytes } }
    var brewUnusedBytes: Int64 { brewUnused.reduce(0) { $0 + $1.bytes } }
    /// Loose and unreachable objects git gc would pack or prune. Packing shrinks them, so the real saving is lower.
    var gitBytes: Int64 { repos.reduce(0) { $0 + $1.estimate } }
    /// Leaves out Homebrew downloads, which Junk already counts.
    var reclaimableBytes: Int64 { brewItems.filter { $0.kind != .download }.reduce(0) { $0 + $1.bytes } + brewUnusedBytes + gitBytes }
    var itemCount: Int { brewItems.filter { $0.kind != .download }.count + brewUnused.count + repos.count }

    func scan() async {
        phase = .scanning(String(localized: "Asking Homebrew what it would clean…"))
        let reporter = ProgressReporter { [weak self] message in
            guard let self, case .scanning = self.phase else { return }
            self.phase = .scanning(message)
        }
        let generation = UUID()
        scanGeneration = generation
        let result = await offPool { MaintenanceScanner.scan(progress: reporter) }
        guard scanGeneration == generation else { return }
        scanGeneration = nil
        brewInstalled = result.brewInstalled
        brewItems = result.brewItems
        brewUnused = result.brewUnused
        repos = result.repos
        healthyRepoCount = result.healthyRepoCount
        dropExcluded()
        phase = .done(.now)
    }

    func cancelScan() {
        guard scanGeneration != nil else { return }
        scanGeneration = nil
        phase = brewItems.isEmpty && repos.isEmpty ? .idle : .done(.now)
    }
    func suggestions() -> [CleanupSuggestion] { [] }

    func forget(paths: Set<String>) {
        brewItems.removeAll { paths.containsPathOrAncestor(of: $0.url.path) }
        repos.removeAll { paths.containsPathOrAncestor(of: $0.url.path) }
    }

    // MARK: Actions

    func runBrewCleanup() async {
        guard running == nil, let brew = MaintenanceScanner.brewPath else { return }
        running = .brewCleanup
        let out = await offPool { Shell.run(brew, ["cleanup"], env: MaintenanceScanner.brewEnv, timeout: 900) }
        running = nil
        report(out, success: String(localized: "Homebrew cleaned up"), freed: MaintenanceScanner.freed(in: out.out + out.err))
        await scan()
    }

    func runBrewAutoremove() async {
        guard running == nil, let brew = MaintenanceScanner.brewPath else { return }
        running = .brewAutoremove
        let bytes = brewUnusedBytes
        let out = await offPool { Shell.run(brew, ["autoremove"], env: MaintenanceScanner.brewEnv, timeout: 900) }
        running = nil
        report(out, success: String(localized: "Removed unused Homebrew dependencies"), freed: out.ok ? bytes : nil)
        await scan()
    }

    func gc(_ repo: GitRepoStatus) async {
        guard running == nil else { return }
        running = .gc(repo.id)
        let freed = await offPool { MaintenanceScanner.gc(repo) }
        running = nil
        finishGC([repo], freed: freed)
    }

    func gcAll() async {
        guard running == nil else { return }
        running = .gcAll
        let targets = repos.filter { !$0.busy }
        let freed = await offPool { targets.compactMap { MaintenanceScanner.gc($0) }.reduce(0, +) }
        running = nil
        finishGC(targets, freed: freed)
    }

    private func finishGC(_ targets: [GitRepoStatus], freed: Int64?) {
        guard let freed else {
            AppModel.shared.showToast(Toast(message: String(localized: "git gc didn't finish"),
                                            detail: String(localized: "The repository may be in use. Try again in a moment."), isError: true))
            return
        }
        let ids = Set(targets.map(\.id))
        repos.removeAll { ids.contains($0.id) }
        healthyRepoCount += ids.count
        AppModel.shared.showToast(Toast(message: String(localized: "Packed \(Fmt.count(ids.count, "repository", "repositories"))"),
                                        detail: String(localized: "Freed \(Fmt.bytes(max(0, freed))).")))
        AppModel.shared.refreshVolume()
    }

    private func report(_ out: Shell.Output, success: String, freed: Int64?) {
        if out.ok {
            AppModel.shared.showToast(Toast(message: success, detail: freed.map { String(localized: "Freed \(Fmt.bytes($0)).") }))
            AppModel.shared.refreshVolume()
        } else {
            let detail = (out.err.isEmpty ? out.out : out.err).split(separator: "\n").suffix(2).joined(separator: "\n")
            AppModel.shared.showToast(Toast(message: String(localized: "Homebrew didn't finish"), detail: detail.isEmpty ? nil : detail, isError: true))
        }
    }
}

struct BrewItem: Identifiable, Hashable, Sendable {
    enum Kind: Sendable { case oldVersion, homebrewFiles, download, log, unusedFormula }
    let url: URL
    let name: String
    let bytes: Int64
    let kind: Kind
    var id: String { url.path }
}

struct GitRepoStatus: Identifiable, Hashable, Sendable {
    let url: URL
    let looseBytes: Int64
    let garbageBytes: Int64
    let packCount: Int
    let prunableWorktrees: Int
    /// Something else is using the repository right now (a lock file exists).
    let busy: Bool
    var id: String { url.path }
    var name: String { url.lastPathComponent }
    var estimate: Int64 { looseBytes + garbageBytes }
}

struct MaintenanceScanResult: Sendable {
    var brewInstalled = false
    var brewItems: [BrewItem] = []
    var brewUnused: [BrewItem] = []
    var repos: [GitRepoStatus] = []
    var healthyRepoCount = 0
}

enum MaintenanceScanner {
    static var brewPath: String? { Shell.find(["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]) }

    /// Keeps Homebrew from updating itself or printing hints while Reclaim runs it.
    static let brewEnv = ["HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_INSTALL_CLEANUP": "1", "HOMEBREW_NO_ENV_HINTS": "1",
                          "HOMEBREW_NO_ANALYTICS": "1", "HOMEBREW_NO_COLOR": "1", "HOMEBREW_NO_EMOJI": "1"]

    /// git from Homebrew or the developer tools. The /usr/bin/git shim is used only when developer tools are installed,
    /// because otherwise it opens the "install command line tools" prompt.
    static var gitPath: String? {
        if let found = Shell.find(["/opt/homebrew/bin/git", "/usr/local/bin/git", "/Library/Developer/CommandLineTools/usr/bin/git",
                                   "/Applications/Xcode.app/Contents/Developer/usr/bin/git"]) { return found }
        return ToolchainScanner.developerDir != nil ? "/usr/bin/git" : nil
    }

    static func scan(progress: ProgressReporter?) -> MaintenanceScanResult {
        var result = MaintenanceScanResult()
        if let brew = brewPath {
            result.brewInstalled = true
            let preview = Shell.run(brew, ["cleanup", "-n"], env: brewEnv, timeout: 180)
            result.brewItems = parseCleanup(preview.out)
            progress?.report(String(localized: "Looking for unused Homebrew dependencies…"), force: true)
            let unused = Shell.run(brew, ["autoremove", "-n"], env: brewEnv, timeout: 180)
            let cellar = URL(fileURLWithPath: brew).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Cellar")
            result.brewUnused = parseAutoremove(unused.out).map { name in
                let url = cellar.appendingPathComponent(name)
                return BrewItem(url: url, name: name, bytes: FS.allocatedSize(of: url), kind: .unusedFormula)
            }
        }
        progress?.report(String(localized: "Checking your git repositories…"), force: true)
        if let git = gitPath {
            let repos = CodeIndex.scan().repos
            var statuses = [GitRepoStatus?](repeating: nil, count: repos.count)
            DispatchQueue.concurrentPerform(iterations: repos.count) { i in statuses[i] = status(of: repos[i], git: git) }
            let all = statuses.compactMap { $0 }
            result.repos = all.filter(needsMaintenance).sorted { $0.estimate > $1.estimate }
            result.healthyRepoCount = all.count - result.repos.count
        }
        return result
    }

    static func needsMaintenance(_ r: GitRepoStatus) -> Bool {
        r.looseBytes >= 20 * 1_048_576 || r.garbageBytes > 0 || r.packCount >= 25 || r.prunableWorktrees > 0
    }

    static func status(of repo: URL, git: String) -> GitRepoStatus? {
        let out = Shell.run(git, ["-C", repo.path, "count-objects", "-v"], timeout: 30)
        guard out.ok else { return nil }
        var values: [String: Int64] = [:]
        for line in out.out.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, let n = Int64(parts[1]) { values[parts[0]] = n }
        }
        let worktrees = Shell.run(git, ["-C", repo.path, "worktree", "list", "--porcelain"], timeout: 30).out
        let prunable = worktrees.split(separator: "\n").filter { $0.hasPrefix("prunable") }.count
        let dotGit = repo.appendingPathComponent(".git")
        let busy = FS.exists(dotGit.appendingPathComponent("index.lock")) || FS.exists(dotGit.appendingPathComponent("gc.pid"))
        return GitRepoStatus(url: repo, looseBytes: (values["size"] ?? 0) * 1024, garbageBytes: (values["size-garbage"] ?? 0) * 1024,
                             packCount: Int(values["packs"] ?? 0), prunableWorktrees: prunable, busy: busy)
    }

    /// Runs git gc (and worktree prune when needed) and returns how much the .git folder shrank, or nil on failure.
    static func gc(_ repo: GitRepoStatus) -> Int64? {
        guard let git = gitPath, !repo.busy else { return nil }
        let dotGit = repo.url.appendingPathComponent(".git")
        let before = FS.allocatedSize(of: dotGit)
        if repo.prunableWorktrees > 0 { _ = Shell.run(git, ["-C", repo.url.path, "worktree", "prune"], timeout: 60) }
        let out = Shell.run(git, ["-C", repo.url.path, "gc", "--quiet"], timeout: 900)
        guard out.ok else { return nil }
        return before - FS.allocatedSize(of: dotGit)
    }

    // MARK: Parsing Homebrew output

    /// "Would remove: /opt/homebrew/Cellar/node/22.1.0 (2,345 files, 75.2MB)"
    static func parseCleanup(_ text: String) -> [BrewItem] {
        guard let re = try? NSRegularExpression(pattern: #"^Would remove: (.+?) \((?:[0-9,]+ files?, )?([0-9.]+)\s*([KMGT]?B)\)$"#,
                                                options: [.anchorsMatchLines]) else { return [] }
        return re.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { m in
            guard let p = Range(m.range(at: 1), in: text), let n = Range(m.range(at: 2), in: text), let u = Range(m.range(at: 3), in: text),
                  let value = Double(text[n]) else { return nil }
            let path = String(text[p])
            let factor: Double = ["B": 1, "KB": 1024, "MB": 1_048_576, "GB": 1_073_741_824, "TB": 1_099_511_627_776][String(text[u])] ?? 1
            let url = URL(fileURLWithPath: path)
            let kind: BrewItem.Kind = path.contains("/Cellar/") || path.contains("/Caskroom/") ? .oldVersion
                : path.contains("/Caches/") ? .download : path.contains("/Logs/") ? .log : .homebrewFiles
            let name: String
            switch kind {
            case .oldVersion: name = "\(url.deletingLastPathComponent().lastPathComponent) \(url.lastPathComponent)"
            case .homebrewFiles: name = "\(url.deletingLastPathComponent().lastPathComponent) \(url.lastPathComponent)"
            default: name = url.lastPathComponent
            }
            return BrewItem(url: url, name: name, bytes: Int64(value * factor), kind: kind)
        }
    }

    /// "==> Would autoremove 3 unneeded formulae:" followed by one name per line.
    static func parseAutoremove(_ text: String) -> [String] {
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let start = lines.firstIndex(where: { $0.hasPrefix("==> Would autoremove") || $0.hasPrefix("==> Would uninstall") }) else { return [] }
        var names: [String] = []
        for line in lines[(start + 1)...] {
            if line.hasPrefix("==>") || line.isEmpty { break }
            names.append(line)
        }
        return names
    }

    /// "This operation has freed approximately 139.4MB of disk space."
    static func freed(in text: String) -> Int64? {
        guard let m = CodeIndex.matches(#"freed approximately ([0-9.]+[KMGT]?B)"#, in: text).first else { return nil }
        let unit = m.drop { $0.isNumber || $0 == "." }
        let factor: Double = ["B": 1, "KB": 1024, "MB": 1_048_576, "GB": 1_073_741_824, "TB": 1_099_511_627_776][String(unit)] ?? 1
        return Double(m.prefix { $0.isNumber || $0 == "." }).map { Int64($0 * factor) }
    }
}
