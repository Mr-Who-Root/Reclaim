import CoreServices
import Foundation

/// A kind of SDK or toolchain that collects old versions.
enum ToolFamily: String, CaseIterable, Identifiable, Sendable {
    case androidNDK, androidPlatforms, androidBuildTools, androidCMake, simulators, xcode, jdk, node, python, ruby, rust, go

    var id: String { rawValue }

    var title: String {
        switch self {
        case .androidNDK: return String(localized: "Android NDK")
        case .androidPlatforms: return String(localized: "Android SDK platforms")
        case .androidBuildTools: return String(localized: "Android build tools")
        case .androidCMake: return String(localized: "Android CMake")
        case .simulators: return String(localized: "Simulator runtimes")
        case .xcode: return String(localized: "Xcode")
        case .jdk: return String(localized: "Java JDKs")
        case .node: return String(localized: "Node.js versions")
        case .python: return String(localized: "Python versions")
        case .ruby: return String(localized: "Ruby versions")
        case .rust: return String(localized: "Rust toolchains")
        case .go: return String(localized: "Go versions")
        }
    }

    var icon: String {
        switch self {
        case .androidNDK, .androidPlatforms, .androidBuildTools, .androidCMake: return "candybarphone"
        case .simulators: return "ipad.and.iphone"
        case .xcode: return "hammer"
        case .jdk: return "cup.and.saucer"
        case .node: return "hexagon"
        case .python: return "chevron.left.forwardslash.chevron.right"
        case .ruby: return "diamond"
        case .rust: return "gearshape"
        case .go: return "hare"
        }
    }

    var explanation: String {
        switch self {
        case .androidNDK: return String(localized: "Native development kits, often 1–2 GB each. Android Studio downloads a version again if a project needs it.")
        case .androidPlatforms: return String(localized: "One per Android API level you've compiled against. Android Studio downloads a level again if a project needs it.")
        case .androidBuildTools: return String(localized: "Build tool versions downloaded by Android Studio and Gradle. They come back automatically when a build needs them.")
        case .androidCMake: return String(localized: "CMake copies used for native Android builds. Android Studio downloads them again when needed.")
        case .simulators: return String(localized: "iOS, watchOS, tvOS and visionOS simulator systems, several gigabytes each. Download one again in Xcode › Settings › Components.")
        case .xcode: return String(localized: "Extra copies of Xcode, such as betas or older versions. Remove one with Uninstall an App.")
        case .jdk: return String(localized: "Java development kits from Gradle, IntelliJ, SDKMAN and installers. Projects that ask for a version get it downloaded again.")
        case .node: return String(localized: "Node versions from nvm, fnm, Volta, asdf and mise. Global npm packages installed into a version go with it.")
        case .python: return String(localized: "Python versions from pyenv, uv, asdf, mise and python.org. Virtual environments made from a version stop working without it.")
        case .ruby: return String(localized: "Ruby versions from rbenv, RVM, chruby, asdf and mise, with the gems installed into each.")
        case .rust: return String(localized: "Toolchains rustup installed. Get one back with rustup toolchain install.")
        case .go: return String(localized: "Go versions downloaded with golang.org/dl into ~/sdk.")
        }
    }

    /// Android pieces come back on their own when a build needs them; other runtimes may carry things you installed into them.
    var isSafe: Bool {
        switch self {
        case .androidNDK, .androidPlatforms, .androidBuildTools, .androidCMake: return true
        default: return false
        }
    }
}

struct ToolVersion: Identifiable, Hashable, Sendable {
    enum Removal: Hashable, Sendable {
        /// Move to the Trash, along with these related files.
        case trash(extra: [URL])
        /// Root-owned; Finder asks for an administrator password.
        case finder
        /// `xcrun simctl runtime delete <id>`
        case simctl(String)
        /// An app: hand over to Uninstall an App.
        case uninstallApp
        /// Can't be removed here (bundled with Xcode, or not deletable).
        case none
    }

    let family: ToolFamily
    let name: String
    let version: String
    let url: URL
    var bytes: Int64 = 0
    var source: String
    var removal: Removal
    var isDefault = false
    var isNewest = false
    var inUse = false
    var usedBy: [String] = []
    var note: String? = nil
    var simID: String? = nil
    /// Overrides the family's safety (e.g. an already-unpacked download is always safe to remove).
    var safe: Bool? = nil

    var isSafe: Bool { safe ?? family.isSafe }

    var id: String { simID ?? url.path }

    /// Why Reclaim keeps this version, or nil when nothing needs it.
    var keepReason: String? {
        if case .none = removal { return String(localized: "Can't be removed") }
        if inUse { return String(localized: "In use") }
        if isDefault { return String(localized: "Default") }
        if !usedBy.isEmpty {
            return usedBy.count == 1 ? String(localized: "Used by \(usedBy[0])") : String(localized: "Used by \(Fmt.count(usedBy.count, "project"))")
        }
        if isNewest { return String(localized: "Newest") }
        return nil
    }

    var isRemovable: Bool { keepReason == nil }
    /// Removable by moving to the Trash from the list (simulators and apps have their own buttons).
    var isTrashable: Bool {
        switch removal { case .trash, .finder: return isRemovable; default: return false }
    }
}

enum ToolchainScanner {
    static func scan(progress: ProgressReporter? = nil) -> [ToolVersion] {
        let index = CodeIndex.scan()
        var found: [ToolVersion] = []
        progress?.report(String(localized: "Looking for Android SDK parts…"), force: true)
        found += android()
        progress?.report(String(localized: "Looking for Xcode and simulators…"), force: true)
        found += xcodes() + simulatorRuntimes()
        progress?.report(String(localized: "Looking for JDKs and language versions…"), force: true)
        found += jdks() + nodes() + pythons() + rubies() + rusts() + gos()

        // What's in use right now, what projects ask for, and what's the default.
        let running = runningExecutables()
        for i in found.indices {
            let base = found[i].url.path + "/"
            found[i].inUse = running.contains { $0.hasPrefix(base) }
        }
        applyPins(&found, index: index)
        markNewest(&found)

        progress?.report(String(localized: "Measuring versions…"), force: true)
        let toMeasure = found.indices.filter { found[$0].bytes == 0 }
        var sizes = [Int64](repeating: 0, count: found.count)
        let urls = found.map(\.url)
        DispatchQueue.concurrentPerform(iterations: toMeasure.count) { k in
            let i = toMeasure[k]
            let size = urls[i].pathExtension == "app" ? spotlightSize(urls[i]) ?? FS.allocatedSize(of: urls[i]) : FS.allocatedSize(of: urls[i])
            sizes[i] = size
        }
        for i in toMeasure { found[i].bytes = sizes[i] }
        let order = Dictionary(uniqueKeysWithValues: ToolFamily.allCases.enumerated().map { ($1, $0) })
        return found.filter { $0.bytes > 0 || $0.family == .simulators }.sorted { a, b in
            if a.family != b.family { return order[a.family]! < order[b.family]! }
            return compare(b.version, a.version)
        }
    }

    // MARK: Android

    static var androidSDK: URL {
        for key in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] {
            if let v = ProcessInfo.processInfo.environment[key], FS.isDirectory(URL(fileURLWithPath: v)) { return URL(fileURLWithPath: v) }
        }
        return FS.library("Android/sdk")
    }

    static func android() -> [ToolVersion] {
        let sdk = androidSDK
        var out: [ToolVersion] = []
        func add(_ family: ToolFamily, _ folder: String, name: (String) -> String, version: (String) -> String = { $0 }) {
            for dir in FS.children(of: sdk.appendingPathComponent(folder)) where FS.isDirectory(dir) {
                let v = dir.lastPathComponent
                out.append(ToolVersion(family: family, name: name(v), version: version(v), url: dir,
                                       source: String(localized: "Android SDK"), removal: .trash(extra: [])))
            }
        }
        add(.androidNDK, "ndk", name: { "NDK \($0)" })
        add(.androidPlatforms, "platforms", name: { "API \($0.replacingOccurrences(of: "android-", with: ""))" },
            version: { $0.replacingOccurrences(of: "android-", with: "") })
        add(.androidBuildTools, "build-tools", name: { String(localized: "Build tools \($0)") })
        add(.androidCMake, "cmake", name: { "CMake \($0)" })
        let legacy = sdk.appendingPathComponent("ndk-bundle")
        if FS.isDirectory(legacy) {
            let v = properties(legacy.appendingPathComponent("source.properties"))["Pkg.Revision"] ?? "ndk-bundle"
            out.append(ToolVersion(family: .androidNDK, name: "NDK \(v) (ndk-bundle)", version: v, url: legacy,
                                   source: String(localized: "Android SDK"), removal: .trash(extra: [])))
        }
        return out
    }

    // MARK: Xcode & simulators

    static var developerDir: String? {
        let o = Shell.run("/usr/bin/xcode-select", ["-p"], timeout: 10)
        let path = o.out.trimmingCharacters(in: .whitespacesAndNewlines)
        return o.ok && FS.exists(URL(fileURLWithPath: path)) ? path : nil
    }

    static func xcodes() -> [ToolVersion] {
        let selected = developerDir
        var out: [ToolVersion] = []
        for folder in [URL(fileURLWithPath: "/Applications"), FS.home.appendingPathComponent("Applications")] {
            for app in FS.children(of: folder) where app.pathExtension == "app" && app.lastPathComponent.lowercased().hasPrefix("xcode") {
                guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any],
                      info["CFBundleIdentifier"] as? String == "com.apple.dt.Xcode" else { continue }
                let version = info["CFBundleShortVersionString"] as? String ?? "?"
                var v = ToolVersion(family: .xcode, name: "\(app.deletingPathExtension().lastPathComponent) \(version)", version: version,
                                    url: app, source: FS.abbreviate(folder.path), removal: .uninstallApp)
                v.isDefault = selected?.hasPrefix(app.path + "/") == true
                out.append(v)
            }
        }
        return out
    }

    static func simulatorRuntimes() -> [ToolVersion] {
        guard let dev = developerDir, dev.contains(".app/") else { return [] }
        let list = Shell.run("/usr/bin/xcrun", ["simctl", "runtime", "list", "-j"], timeout: 30)
        let devices = Shell.run("/usr/bin/xcrun", ["simctl", "list", "devices", "-j"], timeout: 30)
        return parseRuntimes(list.out, devices: devices.out)
    }

    /// From `simctl runtime list -j` (keyed by runtime UUID) and `simctl list devices -j` (devices per runtime identifier).
    static func parseRuntimes(_ json: String, devices: String) -> [ToolVersion] {
        guard let runtimes = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: [String: Any]] else { return [] }
        let deviceMap = ((try? JSONSerialization.jsonObject(with: Data(devices.utf8))) as? [String: Any])?["devices"] as? [String: [Any]] ?? [:]
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return runtimes.compactMap { uuid, r in
            let platformID = r["platformIdentifier"] as? String ?? ""
            let platform = platformID.contains("iphone") ? "iOS" : platformID.contains("watch") ? "watchOS"
                : platformID.contains("appletv") ? "tvOS" : platformID.contains("xr") ? "visionOS" : "Simulator"
            let version = r["version"] as? String ?? "?"
            let build = r["build"] as? String
            let runtimeID = r["runtimeIdentifier"] as? String ?? ""
            let path = r["path"] as? String ?? r["runtimeBundlePath"] as? String ?? "/Library/Developer/CoreSimulator"
            var v = ToolVersion(family: .simulators, name: "\(platform) \(version)" + (build.map { " (\($0))" } ?? ""),
                                version: version, url: URL(fileURLWithPath: path), source: platform,
                                removal: (r["deletable"] as? Bool ?? true) ? .simctl(uuid) : .none)
            v.bytes = (r["sizeBytes"] as? NSNumber)?.int64Value ?? 0
            v.simID = uuid
            let count = deviceMap[runtimeID]?.count ?? 0
            var notes = [Fmt.count(count, "simulator device")]
            if let last = (r["lastUsedAt"] as? String).flatMap({ iso.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) }) {
                notes.append(String(localized: "last used \(Fmt.relative(last))"))
            }
            v.note = notes.joined(separator: " · ")
            return v
        }
    }

    // MARK: Java

    static func jdks() -> [ToolVersion] {
        var out: [ToolVersion] = []
        let javaHome = Shell.run("/usr/libexec/java_home", [], timeout: 10)
        let defaultHome = javaHome.ok ? javaHome.out.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        func add(_ dir: URL, source: String, removal: ToolVersion.Removal) {
            // Gradle nests the JDK one level down (eclipse_adoptium-25-…/jdk-25.0.3+9/Contents/Home).
            let candidates = [dir] + FS.children(of: dir).filter { FS.isDirectory($0) }
            let root = candidates.first { FS.exists($0.appendingPathComponent("Contents/Home/release")) || FS.exists($0.appendingPathComponent("release")) } ?? dir
            let home = FS.exists(root.appendingPathComponent("Contents/Home")) ? root.appendingPathComponent("Contents/Home") : root
            let release = properties(home.appendingPathComponent("release"))
            let version = release["JAVA_VERSION"] ?? dir.lastPathComponent
            let vendor = release["IMPLEMENTOR"].map { " · \($0)" } ?? ""
            var v = ToolVersion(family: .jdk, name: "JDK \(version)", version: version, url: dir, source: source + vendor, removal: removal)
            v.isDefault = defaultHome.map { $0.hasPrefix(dir.path) } ?? false
            out.append(v)
        }
        for dir in FS.children(of: URL(fileURLWithPath: "/Library/Java/JavaVirtualMachines")) where dir.pathExtension == "jdk" {
            add(dir, source: String(localized: "Installer"), removal: .finder)
        }
        for dir in FS.children(of: FS.library("Java/JavaVirtualMachines")) where FS.isDirectory(dir) {
            add(dir, source: "IntelliJ", removal: .trash(extra: []))
        }
        let sdkman = FS.home.appendingPathComponent(".sdkman/candidates/java")
        let sdkmanCurrent = (try? FileManager.default.destinationOfSymbolicLink(atPath: sdkman.appendingPathComponent("current").path))
            .map { URL(fileURLWithPath: $0, relativeTo: sdkman).standardizedFileURL.lastPathComponent }
        for dir in FS.children(of: sdkman) where dir.lastPathComponent != "current" && FS.isDirectory(dir) {
            add(dir, source: "SDKMAN", removal: .trash(extra: []))
            if dir.lastPathComponent == sdkmanCurrent { out[out.count - 1].isDefault = true }
        }
        let gradle = FS.home.appendingPathComponent(".gradle/jdks")
        for item in FS.children(of: gradle) {
            if FS.isDirectory(item) {
                add(item, source: "Gradle", removal: .trash(extra: []))
            } else if ["gz", "zip"].contains(item.pathExtension) {
                // The download Gradle extracted the JDK from; the JDK keeps working without it.
                var v = ToolVersion(family: .jdk, name: item.lastPathComponent, version: "0", url: item,
                                    source: String(localized: "Gradle download"), removal: .trash(extra: []))
                v.note = String(localized: "Download already unpacked")
                v.safe = true
                out.append(v)
            }
        }
        for manager in [(".asdf/installs/java", "asdf"), (".local/share/mise/installs/java", "mise")] {
            for dir in FS.children(of: FS.home.appendingPathComponent(manager.0)) where FS.isDirectory(dir) {
                add(dir, source: manager.1, removal: .trash(extra: []))
            }
        }
        return out
    }

    // MARK: Node, Python, Ruby, Rust, Go

    static func nodes() -> [ToolVersion] {
        var out: [ToolVersion] = []
        let home = FS.home
        func add(_ dir: URL, _ version: String, _ source: String) {
            let v = version.hasPrefix("v") ? String(version.dropFirst()) : version
            out.append(ToolVersion(family: .node, name: "Node \(v)", version: v, url: dir, source: source, removal: .trash(extra: [])))
        }
        for dir in FS.children(of: home.appendingPathComponent(".nvm/versions/node")) where FS.isDirectory(dir) { add(dir, dir.lastPathComponent, "nvm") }
        for base in [FS.library("Application Support/fnm/node-versions"), home.appendingPathComponent(".local/share/fnm/node-versions")] {
            for dir in FS.children(of: base) where FS.isDirectory(dir) { add(dir, dir.lastPathComponent, "fnm") }
        }
        for dir in FS.children(of: home.appendingPathComponent(".volta/tools/image/node")) where FS.isDirectory(dir) { add(dir, dir.lastPathComponent, "Volta") }
        for dir in FS.children(of: home.appendingPathComponent(".asdf/installs/nodejs")) where FS.isDirectory(dir) { add(dir, dir.lastPathComponent, "asdf") }
        for dir in FS.children(of: home.appendingPathComponent(".local/share/mise/installs/node")) where FS.isDirectory(dir) && !isLink(dir) { add(dir, dir.lastPathComponent, "mise") }
        for dir in FS.children(of: home.appendingPathComponent("n/n/versions/node")) where FS.isDirectory(dir) { add(dir, dir.lastPathComponent, "n") }

        // Defaults: nvm's default alias, fnm's default alias, Volta's platform, global asdf/mise versions.
        let installed = out.map(\.version)
        var defaults: [String] = []
        if let alias = resolveNvmAlias("default", installed: installed) { defaults.append(alias) }
        for base in [FS.library("Application Support/fnm/aliases/default"), home.appendingPathComponent(".local/share/fnm/aliases/default")] {
            if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: base.path) {
                defaults.append(URL(fileURLWithPath: target).deletingLastPathComponent().lastPathComponent)
            }
        }
        if let data = FileManager.default.contents(atPath: home.appendingPathComponent(".volta/tools/user/platform.json").path),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let runtime = (json["node"] as? [String: Any])?["runtime"] as? String { defaults.append(runtime) }
        defaults += globalVersions(.node)
        markDefaults(&out, defaults)
        return out
    }

    /// Follows nvm aliases ("default" → "lts/*" → "lts/jod" → "v22.11.0").
    static func resolveNvmAlias(_ name: String, installed: [String], depth: Int = 0) -> String? {
        guard depth < 6 else { return nil }
        let file = FS.home.appendingPathComponent(".nvm/alias").appendingPathComponent(name)
        guard let raw = try? String(contentsOf: file, encoding: .utf8) else {
            return name == "default" ? nil : resolveNodeSpec(name, installed: installed)
        }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if FS.exists(FS.home.appendingPathComponent(".nvm/alias").appendingPathComponent(value)) {
            return resolveNvmAlias(value, installed: installed, depth: depth + 1)
        }
        return resolveNodeSpec(value, installed: installed)
    }

    /// LTS code names, so ".nvmrc: lts/iron" keeps Node 20.
    static let ltsNames = ["argon": 4, "boron": 6, "carbon": 8, "dubnium": 10, "erbium": 12, "fermium": 14, "gallium": 16,
                           "hydrogen": 18, "iron": 20, "jod": 22, "krypton": 24]

    /// Turns "20", "v20.11.1", "lts/iron", "lts/*" or "node" into a version prefix that matches installed versions.
    static func resolveNodeSpec(_ spec: String, installed: [String]) -> String? {
        let s = spec.lowercased().trimmingCharacters(in: .whitespaces)
        let sorted = installed.sorted { compare($0, $1) }
        if ["node", "stable", "latest", "current"].contains(s) { return sorted.last }
        if s == "lts/*" || s == "lts" { return sorted.last { (Int($0.split(separator: ".").first ?? "") ?? 1) % 2 == 0 } }
        if s.hasPrefix("lts/"), let major = ltsNames[String(s.dropFirst(4))] { return "\(major)" }
        let v = s.hasPrefix("v") ? String(s.dropFirst()) : s
        return v.first?.isNumber == true ? v : nil
    }

    static func pythons() -> [ToolVersion] {
        var out: [ToolVersion] = []
        let home = FS.home
        for dir in FS.children(of: home.appendingPathComponent(".pyenv/versions")) where FS.isDirectory(dir) && !isLink(dir) {
            out.append(ToolVersion(family: .python, name: "Python \(dir.lastPathComponent)", version: dir.lastPathComponent, url: dir,
                                   source: "pyenv", removal: .trash(extra: [])))
        }
        for dir in FS.children(of: home.appendingPathComponent(".local/share/uv/python")) where FS.isDirectory(dir) && !isLink(dir) {
            // cpython-3.12.4-macos-aarch64-none
            let parts = dir.lastPathComponent.split(separator: "-")
            let version = parts.count > 1 ? String(parts[1]) : dir.lastPathComponent
            out.append(ToolVersion(family: .python, name: "Python \(version)", version: version, url: dir, source: "uv", removal: .trash(extra: [])))
        }
        for manager in [(".asdf/installs/python", "asdf"), (".local/share/mise/installs/python", "mise")] {
            for dir in FS.children(of: home.appendingPathComponent(manager.0)) where FS.isDirectory(dir) && !isLink(dir) {
                out.append(ToolVersion(family: .python, name: "Python \(dir.lastPathComponent)", version: dir.lastPathComponent, url: dir,
                                       source: manager.1, removal: .trash(extra: [])))
            }
        }
        let framework = URL(fileURLWithPath: "/Library/Frameworks/Python.framework/Versions")
        let current = (try? FileManager.default.destinationOfSymbolicLink(atPath: framework.appendingPathComponent("Current").path))
            .map { URL(fileURLWithPath: $0).lastPathComponent }
        for dir in FS.children(of: framework) where dir.lastPathComponent != "Current" && FS.isDirectory(dir) {
            var v = ToolVersion(family: .python, name: "Python \(dir.lastPathComponent)", version: dir.lastPathComponent, url: dir,
                                source: "python.org", removal: .finder)
            v.isDefault = dir.lastPathComponent == current
            out.append(v)
        }
        var defaults = globalVersions(.python)
        if let text = try? String(contentsOf: home.appendingPathComponent(".pyenv/version"), encoding: .utf8) {
            defaults += text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        }
        markDefaults(&out, defaults, sources: ["pyenv", "asdf", "mise"])
        return out
    }

    static func rubies() -> [ToolVersion] {
        var out: [ToolVersion] = []
        let home = FS.home
        for (folder, source) in [(".rbenv/versions", "rbenv"), (".rvm/rubies", "RVM"), (".rubies", "chruby"),
                                 (".asdf/installs/ruby", "asdf"), (".local/share/mise/installs/ruby", "mise")] {
            for dir in FS.children(of: home.appendingPathComponent(folder)) where FS.isDirectory(dir) && !isLink(dir) && dir.lastPathComponent != "default" {
                let version = dir.lastPathComponent.replacingOccurrences(of: "ruby-", with: "")
                out.append(ToolVersion(family: .ruby, name: "Ruby \(version)", version: version, url: dir, source: source, removal: .trash(extra: [])))
            }
        }
        var defaults = globalVersions(.ruby)
        if let text = try? String(contentsOf: home.appendingPathComponent(".rbenv/version"), encoding: .utf8) {
            defaults.append(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        markDefaults(&out, defaults)
        return out
    }

    static func rusts() -> [ToolVersion] {
        let rustup = FS.home.appendingPathComponent(".rustup")
        let settings = (try? String(contentsOf: rustup.appendingPathComponent("settings.toml"), encoding: .utf8)) ?? ""
        let defaultToolchain = CodeIndex.matches(#"default_toolchain\s*=\s*"([^"]+)""#, in: settings).first
        return FS.children(of: rustup.appendingPathComponent("toolchains")).filter { FS.isDirectory($0) && !isLink($0) }.map { dir in
            let name = dir.lastPathComponent
            let hash = rustup.appendingPathComponent("update-hashes").appendingPathComponent(name)
            var v = ToolVersion(family: .rust, name: name, version: name, url: dir, source: "rustup",
                                removal: .trash(extra: FS.exists(hash) ? [hash] : []))
            if let d = defaultToolchain { v.isDefault = name == d || name.hasPrefix(d + "-") }
            // Channels (stable, beta, nightly) update in place; only pinned versions and dated nightlies pile up.
            v.isNewest = ["stable", "beta", "nightly"].contains { name.hasPrefix($0 + "-") }
            return v
        }
    }

    static func gos() -> [ToolVersion] {
        FS.children(of: FS.home.appendingPathComponent("sdk")).filter { $0.lastPathComponent.hasPrefix("go") && FS.isDirectory($0) }.map { dir in
            let version = String(dir.lastPathComponent.dropFirst(2))
            return ToolVersion(family: .go, name: "Go \(version)", version: version, url: dir, source: "golang.org/dl", removal: .trash(extra: []))
        }
    }

    // MARK: Matching

    /// Global versions set with asdf (~/.tool-versions) or mise (~/.config/mise/config.toml).
    static func globalVersions(_ tool: CodeIndex.Tool) -> [String] {
        var out: [String] = []
        for (file, name) in [(FS.home.appendingPathComponent(".tool-versions"), ".tool-versions"),
                             (FS.home.appendingPathComponent(".config/mise/config.toml"), "mise.toml")] {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            out += CodeIndex.parse(name: name, text: text).filter { $0.0 == tool }.map(\.1)
        }
        return out
    }

    private static func markDefaults(_ versions: inout [ToolVersion], _ specs: [String], sources: Set<String>? = nil) {
        for spec in specs where !spec.isEmpty {
            for i in versions.indices where sources == nil || sources!.contains(versions[i].source) {
                if matches(versions[i], spec) { versions[i].isDefault = true }
            }
        }
    }

    private static func tool(for family: ToolFamily) -> CodeIndex.Tool? {
        switch family {
        case .androidNDK: return .androidNDK
        case .androidPlatforms: return .androidPlatform
        case .androidBuildTools: return .androidBuildTools
        case .androidCMake: return .androidCMake
        case .jdk: return .java
        case .node: return .node
        case .python: return .python
        case .ruby: return .ruby
        case .rust: return .rust
        case .go: return .go
        case .simulators, .xcode: return nil
        }
    }

    static func applyPins(_ versions: inout [ToolVersion], index: CodeIndex.Result) {
        let installedNode = versions.filter { $0.family == .node }.map(\.version)
        for i in versions.indices {
            guard let tool = tool(for: versions[i].family) else { continue }
            var projects = Set<String>()
            for pin in index.pins where pin.tool == tool {
                let spec = tool == .node ? (resolveNodeSpec(pin.value, installed: installedNode) ?? pin.value) : pin.value
                if matches(versions[i], spec) { projects.insert(pin.project) }
            }
            if versions[i].family == .python {
                for (base, users) in index.venvBases where base.hasPrefix(versions[i].url.path) { projects.formUnion(users) }
            }
            versions[i].usedBy = projects.sorted()
        }
    }

    /// Whether a version satisfies a requested spec ("20" matches 20.11.1; "17" matches JDK 17.0.9; exact folder names match too).
    static func matches(_ v: ToolVersion, _ spec: String) -> Bool {
        let s = spec.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return false }
        if s == v.url.lastPathComponent || s == v.version { return true }
        switch v.family {
        case .jdk:
            // "21.0.2-tem", "temurin-21", "17": compare major versions.
            return major(of: s) != nil && major(of: s) == major(of: v.version)
        case .rust:
            return v.url.lastPathComponent.hasPrefix(s + "-")
        case .androidPlatforms:
            return major(of: s) == major(of: v.version) && !s.contains(".") || s == v.version
        case .node, .python, .ruby, .go:
            let clean = s.hasPrefix("v") ? String(s.dropFirst()) : s
            return v.version == clean || v.version.hasPrefix(clean + ".")
        default:
            return v.version.hasPrefix(s + ".")
        }
    }

    private static func major(of text: String) -> Int? {
        // "1.8.0_392" is Java 8.
        let numbers = text.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard let first = numbers.first else { return nil }
        return first == 1 && numbers.count > 1 ? numbers[1] : first
    }

    /// The newest version in each family (per platform for simulators) is always kept.
    static func markNewest(_ versions: inout [ToolVersion]) {
        var newest: [String: Int] = [:]
        for (i, v) in versions.enumerated() where v.family != .rust && v.family != .xcode && v.version != "0" {
            let key = v.family.rawValue + (v.family == .simulators ? v.source : "")
            if let j = newest[key], !compare(versions[j].version, v.version) { continue }
            newest[key] = i
        }
        for i in newest.values { versions[i].isNewest = true }
    }

    /// Natural version order: true when `a` is older than `b`.
    static func compare(_ a: String, _ b: String) -> Bool {
        let x = a.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        let y = b.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : -1, q = i < y.count ? y[i] : -1
            if p != q { return p < q }
        }
        return a < b
    }

    // MARK: Helpers

    private static func isLink(_ url: URL) -> Bool { (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true }

    private static func properties(_ file: URL) -> [String: String] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [:] }
        var out: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 { out[parts[0]] = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
        }
        return out
    }

    /// Executable paths of your running processes, to tell which versions are in use.
    static func runningExecutables() -> [String] {
        DevProcessScanner.allPIDs().compactMap { pid in
            var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            return proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : nil
        }
    }

    /// Spotlight's size for a big bundle like Xcode, which is much faster than walking it.
    static func spotlightSize(_ url: URL) -> Int64? {
        guard let item = MDItemCreateWithURL(nil, url as CFURL),
              let size = MDItemCopyAttribute(item, "kMDItemPhysicalSize" as CFString) as? NSNumber else { return nil }
        return size.int64Value
    }
}
