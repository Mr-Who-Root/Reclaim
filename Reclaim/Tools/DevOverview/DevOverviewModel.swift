import SwiftUI

/// Everything development takes up, by area (Xcode, Android, JavaScript…), measured on disk, with what each
/// developer tool found to review.
@MainActor @Observable
final class DevOverviewModel {
    private(set) var phase: ScanPhase = .idle
    /// Measured size of each area's folders.
    private(set) var measured: [String: Int64] = [:]

    struct Part: Identifiable {
        let title: String
        let bytes: Int64
        let route: Route
        var id: String { "\(route.rawValue):\(title)" }
    }

    struct Area: Identifiable {
        let id: String
        let title: String
        let icon: String
        let color: Color
        let total: Int64
        let parts: [Part]
        var reviewBytes: Int64 { parts.reduce(0) { $0 + $1.bytes } }
    }

    struct Definition {
        let id: String
        let title: String
        let icon: String
        let color: Color
        /// Home-relative (or absolute) folders that make up the area.
        let paths: [String]
        let junkRules: [String]
        let families: [ToolFamily]
    }

    nonisolated static var definitions: [Definition] {
        let brew = MaintenanceScanner.brewPath.map { URL(fileURLWithPath: $0).deletingLastPathComponent().deletingLastPathComponent().path }
        return [
            Definition(id: "xcode", title: String(localized: "Xcode & simulators"), icon: "hammer", color: .blue,
                       paths: ["Library/Developer/Xcode", "Library/Developer/CoreSimulator", "Library/Caches/com.apple.dt.Xcode",
                               "Library/Developer/XCTestDevices", "Library/Caches/CocoaPods"],
                       junkRules: ["derivedData", "deviceSupport", "simCaches", "previews", "archives", "simUnavailable", "simDevices", "cocoapods"],
                       families: [.xcode, .simulators]),
            Definition(id: "android", title: String(localized: "Android"), icon: "candybarphone", color: .green,
                       paths: ["Library/Android/sdk", ".android"],
                       junkRules: ["android", "androidSnapshots", "androidImages", "androidCaches", "genymotion"],
                       families: [.androidNDK, .androidPlatforms, .androidBuildTools, .androidCMake]),
            Definition(id: "jvm", title: String(localized: "Java, Gradle & Maven"), icon: "cup.and.saucer", color: .orange,
                       paths: [".gradle", ".m2", "Library/Java/JavaVirtualMachines", ".sdkman/candidates", ".konan", ".ivy2",
                               "/Library/Java/JavaVirtualMachines"],
                       junkRules: ["gradle"], families: [.jdk]),
            Definition(id: "javascript", title: String(localized: "JavaScript"), icon: "curlybraces", color: .yellow,
                       paths: [".npm", "Library/Caches/Yarn", ".yarn/berry/cache", "Library/pnpm", ".bun", ".nvm/versions", ".volta",
                               "Library/Application Support/fnm", ".local/share/fnm", ".deno", "Library/Caches/deno",
                               "Library/Caches/ms-playwright", ".cache/puppeteer"],
                       junkRules: ["npm", "yarn"], families: [.node]),
            Definition(id: "python", title: String(localized: "Python"), icon: "chevron.left.forwardslash.chevron.right", color: .indigo,
                       paths: ["Library/Caches/pip", ".cache/uv", ".local/share/uv", ".pyenv/versions", "Library/Caches/pypoetry",
                               "miniconda3", "anaconda3", "miniforge3", ".conda", "/Library/Frameworks/Python.framework"],
                       junkRules: ["pip"], families: [.python]),
            Definition(id: "ruby", title: String(localized: "Ruby"), icon: "diamond", color: .red,
                       paths: [".rbenv/versions", ".rvm", ".gem", ".rubies", ".local/share/gem"], junkRules: [], families: [.ruby]),
            Definition(id: "rustgo", title: String(localized: "Rust & Go"), icon: "gearshape", color: .brown,
                       paths: [".cargo", ".rustup", "go/pkg/mod", "Library/Caches/go-build", "sdk"],
                       junkRules: ["cargo"], families: [.rust, .go]),
            Definition(id: "homebrew", title: String(localized: "Homebrew"), icon: "mug", color: .mint,
                       paths: (brew.map { ["\($0)/Cellar", "\($0)/Caskroom"] } ?? []) + ["Library/Caches/Homebrew"],
                       junkRules: ["homebrew"], families: []),
            Definition(id: "docker", title: String(localized: "Docker"), icon: "shippingbox", color: Route.docker.color,
                       // Docker Desktop's and OrbStack's disk images sit in app containers macOS protects, so their size
                       // comes from Docker itself; Colima and Rancher Desktop keep their VMs in your Home folder.
                       paths: [".colima/_lima", ".rd/lima"],
                       junkRules: [], families: []),
            Definition(id: "projects", title: String(localized: "Code projects"), icon: "folder.badge.gearshape", color: .purple,
                       paths: [], junkRules: ["projectsOld", "projectsRecent", "projectEnvs"], families: []),
            Definition(id: "ai", title: String(localized: "AI tools & models"), icon: "brain", color: Route.ai.color,
                       paths: [".ollama/models", ".cache/huggingface", ".lmstudio/models", ".cache/lm-studio", ".cache/whisper",
                               ".cache/torch", "Library/Application Support/nomic.ai"],
                       junkRules: [], families: []),
        ]
    }

    /// Areas with what each tool currently reports, biggest first. Updates as tools scan or clean.
    var areas: [Area] {
        let app = AppModel.shared
        let junk = Dictionary(app.junk.results.map { ($0.rule.id, $0) }, uniquingKeysWith: { a, _ in a })
        return Self.definitions.compactMap { def in
            var parts: [Part] = []
            for id in def.junkRules {
                if let r = junk[id], r.bytes > 0 { parts.append(Part(title: r.rule.title, bytes: r.bytes, route: .junk)) }
            }
            for family in def.families {
                let bytes = app.toolchains.versions.filter { $0.family == family && $0.isRemovable }.reduce(0) { $0 + $1.bytes }
                if bytes > 0 { parts.append(Part(title: family.title, bytes: bytes, route: .toolchains)) }
            }
            var extra: Int64 = 0
            switch def.id {
            case "xcode":
                extra = app.toolchains.versions.filter { $0.family == .simulators || $0.family == .xcode }.reduce(0) { $0 + $1.bytes }
            case "homebrew":
                let brew = app.maintenance.brewItems.filter { $0.kind != .download }.reduce(0) { $0 + $1.bytes } + app.maintenance.brewUnusedBytes
                if brew > 0 { parts.append(Part(title: String(localized: "brew cleanup & autoremove"), bytes: brew, route: .maintenance)) }
            case "docker":
                let reclaim = app.docker.groups.reduce(0) { $0 + $1.reclaimable }
                if reclaim > 0 { parts.append(Part(title: String(localized: "Docker cleanup"), bytes: reclaim, route: .docker)) }
                extra = app.docker.totalUsed
            case "projects":
                extra = measured["git"] ?? 0
                if app.maintenance.gitBytes > 0 {
                    parts.append(Part(title: String(localized: "git gc"), bytes: app.maintenance.gitBytes, route: .maintenance))
                }
            case "ai":
                if app.aiJunk.foundBytes > 0 { parts.append(Part(title: Route.ai.title, bytes: app.aiJunk.foundBytes, route: .ai)) }
            default:
                break
            }
            let parts2 = parts.sorted { $0.bytes > $1.bytes }
            let total = max((measured[def.id] ?? 0) + extra, parts2.reduce(0) { $0 + $1.bytes })
            guard total > 0 else { return nil }
            return Area(id: def.id, title: def.title, icon: def.icon, color: def.color, total: total, parts: parts2)
        }
        .sorted { $0.total > $1.total }
    }

    var totalBytes: Int64 { areas.reduce(0) { $0 + $1.total } }
    var reviewBytes: Int64 { areas.reduce(0) { $0 + $1.reviewBytes } }

    /// Measures every area and runs the developer tools that haven't scanned yet. Nothing is changed.
    func scan() async {
        if case .scanning = phase { return }
        phase = .scanning(String(localized: "Measuring developer folders…"))
        let app = AppModel.shared
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                let sizes = await offPool { Self.measure() }
                self.measured = sizes
            }
            group.addTask { @MainActor in await app.toolchains.scan() }
            group.addTask { @MainActor in await app.maintenance.scan() }
            group.addTask { @MainActor in await app.processes.refresh() }
            if Route.docker.isAvailable { group.addTask { @MainActor in await app.docker.scan() } }
            if !app.junk.phase.isDone { group.addTask { @MainActor in await app.junk.scan() } }
            if !app.aiJunk.phase.isDone { group.addTask { @MainActor in await app.aiJunk.scan() } }
        }
        phase = .done(.now)
    }

    nonisolated static func measure() -> [String: Int64] {
        let defs = definitions
        var jobs: [(String, URL)] = []
        for def in defs {
            for p in def.paths {
                let url = p.hasPrefix("/") ? URL(fileURLWithPath: p) : FS.home.appendingPathComponent(p)
                if FS.exists(url) { jobs.append((def.id, url)) }
            }
        }
        // Git data is each repository's .git folder. Xcode and simulator runtimes come from the toolchain scan.
        for repo in CodeIndex.scan().repos { jobs.append(("git", repo.appendingPathComponent(".git"))) }
        var sizes = [Int64](repeating: 0, count: jobs.count)
        DispatchQueue.concurrentPerform(iterations: jobs.count) { i in sizes[i] = FS.allocatedSize(of: jobs[i].1) }
        var out: [String: Int64] = [:]
        for (i, job) in jobs.enumerated() { out[job.0, default: 0] += sizes[i] }
        return out
    }
}
