import Darwin
import Foundation

/// One of your processes, read from the kernel (libproc), not by parsing `ps`.
struct ProcInfo: Hashable, Sendable {
    let pid: pid_t
    let ppid: pid_t
    let started: Date
    let path: String
    let args: [String]
    let cwd: String?
    /// Memory as Activity Monitor shows it (physical footprint).
    let memory: Int64
    var name: String { (path as NSString).lastPathComponent }
}

/// A developer process and everything it started.
struct DevProcessGroup: Identifiable, Hashable, Sendable {
    enum Status: String, Sendable { case leftBehind, helper, running }
    enum Kind: String, Sendable { case runtime, headlessBrowser, languageServer, buildDaemon, emulator, androidBridge }

    let root: ProcInfo
    /// The root and all of its descendants.
    let members: [ProcInfo]
    let status: Status
    let kind: Kind
    let title: String
    let detail: String
    let ports: [Int]
    /// The app or terminal it runs under, for running processes.
    let parentName: String?
    var id: pid_t { root.pid }
    var memory: Int64 { members.reduce(0) { $0 + $1.memory } }
    var commandLine: String { root.args.joined(separator: " ") }
}

enum DevProcessScanner {
    static func scan() -> [DevProcessGroup] {
        let me = getuid()
        let own = allPIDs().compactMap { info(for: $0, uid: me) }.filter { $0.pid != getpid() }
        let byPID = Dictionary(own.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var children: [pid_t: [ProcInfo]] = [:]
        for p in own { children[p.ppid, default: []].append(p) }
        let managed = launchdManagedPIDs()
        let ports = listeningPorts()

        func descendants(of p: ProcInfo) -> [ProcInfo] {
            var out: [ProcInfo] = [], stack = [p]
            while let next = stack.popLast() {
                out.append(next)
                stack += children[next.pid] ?? []
            }
            return out
        }
        func make(_ root: ProcInfo, _ kind: DevProcessGroup.Kind, _ status: DevProcessGroup.Status, parent: String? = nil) -> DevProcessGroup {
            let members = descendants(of: root)
            let (title, detail) = describe(root, kind)
            return DevProcessGroup(root: root, members: members, status: status, kind: kind, title: title, detail: detail,
                                   ports: Array(Set(members.flatMap { ports[$0.pid] ?? [] })).sorted(), parentName: parent)
        }

        var groups: [DevProcessGroup] = []
        var claimed = Set<pid_t>()
        // Left behind or detached helpers: re-parented to launchd but not a launchd job (apps and services are jobs).
        let shells: Set<String> = ["zsh", "bash", "fish", "sh", "dash", "-zsh", "-bash", "login", "tmux", "screen"]
        for p in own where p.ppid == 1 && !managed.contains(p.pid) {
            if let kind = kind(of: p) {
                let status: DevProcessGroup.Status = (kind == .buildDaemon || kind == .androidBridge) ? .helper : .leftBehind
                let g = make(p, kind, status)
                groups.append(g)
                claimed.formUnion(g.members.map(\.pid))
            } else if shells.contains(p.name), let dev = descendants(of: p).dropFirst().first(where: { kind(of: $0) != nil }),
                      let devKind = kind(of: dev), devKind != .buildDaemon, devKind != .androidBridge {
                // A background job whose terminal closed: an orphaned shell still running a dev process.
                let members = descendants(of: p)
                let (title, detail) = describe(dev, devKind)
                let g = DevProcessGroup(root: p, members: members, status: .leftBehind, kind: devKind, title: title, detail: detail,
                                        ports: Array(Set(members.flatMap { ports[$0.pid] ?? [] })).sorted(), parentName: nil)
                groups.append(g)
                claimed.formUnion(members.map(\.pid))
            }
        }
        // Dev servers you're running from a terminal: dev processes holding a port, under a shell.
        for p in own where !claimed.contains(p.pid) && ports[p.pid] != nil {
            guard kind(of: p) != nil else { continue }
            // Climb to the topmost dev process directly under the shell (e.g. `npm run dev`, not its `vite` child).
            var top = p
            var chain: [ProcInfo] = []
            var cursor = byPID[p.ppid]
            while let c = cursor, c.pid > 1 {
                chain.append(c)
                cursor = byPID[c.ppid]
            }
            for a in chain {
                if kind(of: a) != nil { top = a } else { break }
            }
            guard !claimed.contains(top.pid) else { continue }
            guard chain.contains(where: { shells.contains($0.name) }) else { continue }
            let app = chain.first { $0.path.contains(".app/") }.map { appName(from: $0.path) }
            let g = make(top, kind(of: top) ?? .runtime, .running, parent: app ?? String(localized: "a terminal"))
            groups.append(g)
            claimed.formUnion(g.members.map(\.pid))
        }
        return groups.sorted { $0.memory > $1.memory }
    }

    // MARK: Classification

    private static let runtimes: Set<String> = ["node", "deno", "bun", "ruby", "php", "java", "dotnet", "esbuild", "uvicorn",
                                                "gunicorn", "hypercorn", "rails", "puma", "jupyter-lab", "jupyter-notebook",
                                                "air", "hugo", "caddy", "wrangler", "workerd", "miniflare"]
    private static let languageServers: Set<String> = ["gopls", "rust-analyzer", "sourcekit-lsp", "clangd", "jdtls", "lua-language-server",
                                                       "terraform-ls", "kotlin-language-server", "zls", "ruby-lsp", "solargraph",
                                                       "elixir-ls", "haskell-language-server", "metals", "omnisharp", "dart"]

    static func kind(of p: ProcInfo) -> DevProcessGroup.Kind? {
        let name = p.name.lowercased()
        let joined = p.args.joined(separator: " ")
        let headlessFlag = p.args.contains { $0.hasPrefix("--headless") || $0 == "-headless" }
        if name.contains("chrome-headless-shell") || name == "headless_shell" || p.path.contains("/ms-playwright/")
            || (headlessFlag && ["google chrome for testing", "chromium", "google chrome", "firefox", "microsoft edge"].contains(name)) {
            return .headlessBrowser
        }
        if name.hasPrefix("qemu-system") || name == "emulator" { return .emulator }
        if name == "adb" { return .androidBridge }
        if joined.contains("GradleDaemon") || joined.contains("KotlinCompileDaemon") || ["watchman", "sccache", "bazel"].contains(name) {
            return .buildDaemon
        }
        if languageServers.contains(name) || joined.contains("language-server") || joined.contains("langserver")
            || joined.contains("/tsserver.js") {
            return .languageServer
        }
        // Runtimes bundled inside an app belong to that app (Python's own Python.app is the runtime itself).
        if p.path.contains(".app/Contents/") && !p.path.contains("/Python.framework/") && !p.path.contains("/Python3.framework/") { return nil }
        if runtimes.contains(name) || name.range(of: #"^python[0-9.]*$"#, options: .regularExpression) != nil { return .runtime }
        return nil
    }

    /// A readable name and a one-line description.
    static func describe(_ p: ProcInfo, _ kind: DevProcessGroup.Kind) -> (String, String) {
        let cwd = p.cwd.map { FS.abbreviate($0) }
        let inFolder = cwd.map { String(localized: "in \($0)") }
        switch kind {
        case .headlessBrowser:
            let browser = p.name.lowercased().contains("firefox") ? String(localized: "Headless Firefox") : String(localized: "Headless Chrome")
            if let owner = owner(ofPath: p.path) { return (browser, String(localized: "Downloaded by \(owner)")) }
            return (browser, inFolder ?? "")
        case .emulator:
            if let i = p.args.firstIndex(of: "-avd"), i + 1 < p.args.count {
                return (String(localized: "Android emulator"), p.args[i + 1].replacingOccurrences(of: "_", with: " "))
            }
            return (String(localized: "QEMU virtual machine"), inFolder ?? "")
        case .androidBridge:
            return (String(localized: "Android Debug Bridge"), String(localized: "Keeps a connection to devices and emulators"))
        case .buildDaemon:
            let joined = p.args.joined(separator: " ")
            if joined.contains("GradleDaemon") {
                let version = joined.range(of: #"gradle-(launcher-)?([0-9][0-9.]*[0-9])"#, options: .regularExpression)
                    .map { String(joined[$0]).replacingOccurrences(of: "gradle-launcher-", with: "").replacingOccurrences(of: "gradle-", with: "") }
                return (version.map { String(localized: "Gradle daemon \($0)") } ?? String(localized: "Gradle daemon"),
                        String(localized: "Stops by itself after 3 idle hours"))
            }
            if joined.contains("KotlinCompileDaemon") { return (String(localized: "Kotlin compile daemon"), String(localized: "Started by Gradle builds")) }
            return (p.name, inFolder ?? "")
        case .languageServer:
            return (scriptName(p) ?? p.name, String(localized: "Code editor helper") + (cwd.map { " · \($0)" } ?? ""))
        case .runtime:
            return (scriptName(p) ?? p.name, inFolder ?? "")
        }
    }

    /// "hyperframes preview", "vite", "http.server": the script or module a runtime is running, plus its subcommand.
    static func scriptName(_ p: ProcInfo) -> String? {
        let args = Array(p.args.dropFirst())
        var i = 0
        while i < args.count {
            let a = args[i]
            if a == "-m", i + 1 < args.count { return args[i + 1] + subcommand(args, after: i + 1) }
            // Inline code: name it after the runtime rather than the code itself.
            if ["-e", "--eval", "-p", "--print", "-c"].contains(a) { return "\(p.name) \(a)" }
            if a == "-jar", i + 1 < args.count { return ((args[i + 1] as NSString).lastPathComponent as NSString).deletingPathExtension }
            if a.hasPrefix("-") {
                // Flags that take a value.
                if ["-r", "--require", "--import", "--loader", "-cp", "-classpath", "--cwd"].contains(a) { i += 1 }
                i += 1
                continue
            }
            return label(forScript: a) + subcommand(args, after: i)
        }
        return nil
    }

    private static func subcommand(_ args: [String], after index: Int) -> String {
        guard index + 1 < args.count else { return "" }
        let next = args[index + 1]
        guard !next.hasPrefix("-"), next.count <= 24, next.range(of: #"^[A-Za-z][A-Za-z0-9:_-]*$"#, options: .regularExpression) != nil else { return "" }
        return " " + next
    }

    private static func label(forScript script: String) -> String {
        if let r = script.range(of: "/node_modules/.bin/") { return String(script[r.upperBound...]) }
        if let r = script.range(of: "/node_modules/", options: .backwards) {
            let rest = script[r.upperBound...].split(separator: "/")
            if let first = rest.first {
                if first.hasPrefix("@"), rest.count > 1 { return "\(first)/\(rest[1])" }
                return String(first)
            }
        }
        let url = URL(fileURLWithPath: script)
        let base = url.deletingPathExtension().lastPathComponent
        if ["index", "main", "cli", "server", "app", "start", "run", "bin"].contains(base.lowercased()) {
            return url.deletingLastPathComponent().lastPathComponent + "/" + base
        }
        return base
    }

    /// The tool a downloaded browser belongs to, from where it's stored (~/.cache/<tool>/…, …/node_modules/<pkg>/…).
    static func owner(ofPath path: String) -> String? {
        if path.contains("/ms-playwright/") { return "Playwright" }
        if path.contains("/.cache/puppeteer/") { return "Puppeteer" }
        if let r = path.range(of: "/.cache/") {
            return path[r.upperBound...].split(separator: "/").first.map(String.init)
        }
        if let r = path.range(of: "/node_modules/", options: .backwards) {
            return path[r.upperBound...].split(separator: "/").first.map(String.init)
        }
        return nil
    }

    private static func appName(from path: String) -> String {
        guard let r = path.range(of: ".app/") else { return (path as NSString).lastPathComponent }
        return ((String(path[..<r.lowerBound]) as NSString).lastPathComponent)
    }

    // MARK: Reading processes

    static func allPIDs() -> [pid_t] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 128)
        let n = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        return n > 0 ? Array(pids.prefix(Int(n))).filter { $0 > 0 } : []
    }

    /// Start time of a process, used to make sure a PID still belongs to the same process before signalling it.
    static func startTime(of pid: pid_t) -> Date? {
        var bsd = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout<proc_bsdinfo>.size)) == Int32(MemoryLayout<proc_bsdinfo>.size) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(bsd.pbi_start_tvsec) + TimeInterval(bsd.pbi_start_tvusec) / 1_000_000)
    }

    static func info(for pid: pid_t, uid: uid_t) -> ProcInfo? {
        var bsd = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, size) == size, bsd.pbi_uid == uid else { return nil }
        var pathBuf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count)) > 0 else { return nil }
        let path = String(cString: pathBuf)
        if path.hasPrefix("/System/") || path.hasPrefix("/usr/libexec/") || path.hasPrefix("/Library/Apple/") { return nil }

        var usage = rusage_info_v4()
        let memory: Int64 = withUnsafeMutablePointer(to: &usage) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        } == 0 ? Int64(usage.ri_phys_footprint) : 0

        var vnode = proc_vnodepathinfo()
        let vsize = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        var cwd: String?
        if proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vnode, vsize) == vsize {
            cwd = withUnsafeBytes(of: vnode.pvi_cdir.vip_path) { raw in
                raw.bindMemory(to: CChar.self).baseAddress.map { String(cString: $0) }
            }
            if cwd == "/" || cwd?.isEmpty == true { cwd = nil }
        }
        let started = Date(timeIntervalSince1970: TimeInterval(bsd.pbi_start_tvsec) + TimeInterval(bsd.pbi_start_tvusec) / 1_000_000)
        return ProcInfo(pid: pid, ppid: pid_t(bsd.pbi_ppid), started: started, path: path,
                        args: arguments(of: pid) ?? [path], cwd: cwd, memory: memory)
    }

    private static let argMax: Int = {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        return sysctl(&mib, 2, &value, &size, nil, 0) == 0 ? Int(value) : 262_144
    }()

    /// argv from KERN_PROCARGS2: argc, the executable path, padding, then the arguments.
    static func arguments(of pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var buffer = [UInt8](repeating: 0, count: argMax)
        var size = buffer.count
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var i = MemoryLayout<Int32>.size
        while i < size, buffer[i] != 0 { i += 1 }   // executable path
        while i < size, buffer[i] == 0 { i += 1 }   // padding
        var args: [String] = []
        while i < size, args.count < argc {
            let start = i
            while i < size, buffer[i] != 0 { i += 1 }
            args.append(String(decoding: buffer[start..<i], as: UTF8.self))
            i += 1
        }
        return args.isEmpty ? nil : args
    }

    /// PIDs of your launchd jobs: apps you opened and services such as `brew services`. These aren't leftovers.
    static func launchdManagedPIDs() -> Set<pid_t> {
        let out = Shell.run("/bin/launchctl", ["list"], timeout: 10).out
        return Set(out.split(separator: "\n").dropFirst().compactMap { line in
            line.split(separator: "\t").first.flatMap { pid_t($0) }
        })
    }

    /// TCP ports each process is listening on.
    static func listeningPorts() -> [pid_t: [Int]] {
        let out = Shell.run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpn"], timeout: 15).out
        var result: [pid_t: Set<Int>] = [:]
        var current: pid_t?
        for line in out.split(separator: "\n") {
            if line.hasPrefix("p") { current = pid_t(line.dropFirst()) }
            else if line.hasPrefix("n"), let pid = current, let colon = line.lastIndex(of: ":"), let port = Int(line[line.index(after: colon)...]) {
                result[pid, default: []].insert(port)
            }
        }
        return result.mapValues { $0.sorted() }
    }

    // MARK: Quitting

    /// Sends SIGTERM (or SIGKILL) to every member, children first, skipping any PID that now belongs to another process.
    /// Returns the members still running a few seconds later.
    static func quit(_ group: DevProcessGroup, force: Bool) async -> [ProcInfo] {
        await offPool { quitNow(group, force: force) }
    }

    static func quitNow(_ group: DevProcessGroup, force: Bool) -> [ProcInfo] {
        let targets = group.members.reversed().filter { member in
            guard let started = startTime(of: member.pid) else { return false }
            return abs(started.timeIntervalSince(member.started)) < 1
        }
        for p in targets { kill(p.pid, force ? SIGKILL : SIGTERM) }
        for _ in 0..<15 {
            usleep(200_000)
            if targets.allSatisfy({ !isAlive($0) }) { return [] }
        }
        return targets.filter(isAlive)
    }

    private static func isAlive(_ p: ProcInfo) -> Bool {
        guard let started = startTime(of: p.pid) else { return false }
        return abs(started.timeIntervalSince(p.started)) < 1
    }
}
