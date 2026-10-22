import Foundation

/// One walk over your code folders that collects the toolchain versions projects ask for
/// (.nvmrc, .python-version, ndkVersion…) and the git repositories in them.
enum CodeIndex {
    enum Tool: String, Sendable { case node, python, ruby, java, rust, go, androidNDK, androidPlatform, androidBuildTools, androidCMake }

    struct Pin: Hashable, Sendable {
        let tool: Tool
        let value: String
        let project: String
    }

    struct Result: Sendable {
        var pins: [Pin] = []
        var repos: [URL] = []
        /// Base Python installs that project virtual environments point at, with the projects using them.
        var venvBases: [String: Set<String>] = [:]
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: (date: Date, result: Result)?

    static func scan() -> Result {
        lock.lock()
        if let cache, Date().timeIntervalSince(cache.date) < 60 { lock.unlock(); return cache.result }
        lock.unlock()
        let result = walk(JunkProjects.roots)
        lock.lock(); cache = (.now, result); lock.unlock()
        return result
    }

    static func invalidate() { lock.lock(); cache = nil; lock.unlock() }

    private static let skip: Set<String> = ["node_modules", "Pods", "build", "target", "DerivedData", "dist", "vendor", "Library",
                                            "__pycache__", "venv", "env", "Carthage", "bower_components", "out", "obj", "bin"]
    private static let pinFiles: Set<String> = [".nvmrc", ".node-version", ".python-version", ".ruby-version", ".java-version",
                                                ".sdkmanrc", ".tool-versions", "mise.toml", ".mise.toml", "rust-toolchain",
                                                "rust-toolchain.toml", "go.mod", "Gemfile", "build.gradle", "build.gradle.kts",
                                                "libs.versions.toml", "package.json"]

    static func walk(_ roots: [URL]) -> Result {
        var result = Result()
        var budget = 300_000
        var queue: [(URL, Int, String?)] = roots.map { ($0, 0, nil) }
        while !queue.isEmpty, budget > 0, !Task.isCancelled {
            let (dir, depth, inheritedProject) = queue.removeFirst()
            let children = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey])) ?? []
            budget -= children.count
            let names = Set(children.map(\.lastPathComponent))
            var project = inheritedProject
            if names.contains(".git") {
                result.repos.append(dir)
                project = dir.lastPathComponent
            }
            let label = project ?? dir.lastPathComponent
            for name in names where pinFiles.contains(name) {
                result.pins += pins(in: dir.appendingPathComponent(name), project: label)
            }
            for env in [".venv", "venv", "env"] where names.contains(env) {
                if let base = venvBase(dir.appendingPathComponent(env)) { result.venvBases[base, default: []].insert(label) }
            }
            guard depth < 7 else { continue }
            for child in children {
                let name = child.lastPathComponent
                if name.hasPrefix(".") || skip.contains(name) || name.hasSuffix(".app") || name.hasSuffix(".xcodeproj")
                    || name.hasSuffix(".xcworkspace") { continue }
                guard let v = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]),
                      v.isDirectory == true, v.isSymbolicLink != true, v.isPackage != true else { continue }
                queue.append((child, depth + 1, project))
            }
        }
        return result
    }

    // MARK: Parsing pin files

    static func pins(in file: URL, project: String) -> [Pin] {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
              (attrs[.size] as? Int ?? 0) < 512 * 1024,
              let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return parse(name: file.lastPathComponent, text: text).map { Pin(tool: $0.0, value: $0.1, project: project) }
    }

    /// The (tool, version) pairs a pin file asks for.
    static func parse(name: String, text: String) -> [(Tool, String)] {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        func first(_ pattern: String) -> [String] { matches(pattern, in: text) }
        switch name {
        case ".nvmrc", ".node-version":
            return lines.first.map { [(.node, $0)] } ?? []
        case ".python-version":
            return lines.map { (.python, $0) }
        case ".ruby-version":
            return lines.first.map { [(.ruby, $0.replacingOccurrences(of: "ruby-", with: ""))] } ?? []
        case ".java-version":
            return lines.first.map { [(.java, $0)] } ?? []
        case ".sdkmanrc":
            return lines.compactMap { line in
                let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                return parts.count == 2 && parts[0] == "java" ? (.java, parts[1]) : nil
            }
        case ".tool-versions":
            return lines.flatMap { line -> [(Tool, String)] in
                let parts = line.split(separator: " ").map(String.init)
                guard parts.count >= 2, let tool = asdfTool(parts[0]) else { return [] }
                return parts.dropFirst().filter { $0 != "system" }.map { (tool, $0) }
            }
        case "mise.toml", ".mise.toml":
            var inTools = false
            var out: [(Tool, String)] = []
            for line in lines {
                if line.hasPrefix("[") { inTools = line == "[tools]"; continue }
                guard inTools else { continue }
                let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2, let tool = asdfTool(parts[0].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))) else { continue }
                out += matches(#""([^"]+)""#, in: parts[1]).map { (tool, $0) }
            }
            return out
        case "rust-toolchain":
            if text.contains("channel") { return first(#"channel\s*=\s*"([^"]+)""#).map { (.rust, $0) } }
            return lines.first.map { [(.rust, $0)] } ?? []
        case "rust-toolchain.toml":
            return first(#"channel\s*=\s*"([^"]+)""#).map { (.rust, $0) }
        case "go.mod":
            return first(#"(?m)^toolchain\s+go([0-9][0-9.]*)"#).map { (.go, $0) }
        case "Gemfile":
            return first(#"(?m)^\s*ruby\s+["']([0-9][0-9.]*)["']"#).map { (.ruby, $0) }
        case "package.json":
            return first(#""volta"\s*:\s*\{[^}]*"node"\s*:\s*"([^"]+)""#).map { (.node, $0) }
        case "build.gradle", "build.gradle.kts":
            var out: [(Tool, String)] = []
            out += first(#"ndkVersion\s*=?\s*["']([0-9][0-9.]*)["']"#).map { (.androidNDK, $0) }
            out += first(#"compileSdk(?:Version)?\s*=?\s*\(?\s*["']?(?:android-)?([0-9]+(?:\.[0-9]+)?)"#).map { (.androidPlatform, $0) }
            out += first(#"buildToolsVersion\s*=?\s*["']([0-9][0-9.]*)["']"#).map { (.androidBuildTools, $0) }
            out += first(#"(?s)cmake\s*\{[^}]*?version\s*=?\s*["']([0-9][0-9.]*)["']"#).map { (.androidCMake, $0) }
            out += first(#"(?:jvmToolchain|JavaLanguageVersion\.of)\s*\(\s*([0-9]+)\s*\)"#).map { (.java, $0) }
            return out
        case "libs.versions.toml":
            var out: [(Tool, String)] = []
            for line in lines {
                guard let kv = matchPairs(#"^([A-Za-z0-9_.-]+)\s*=\s*"([^"]+)""#, in: line).first else { continue }
                let key = kv.0.lowercased()
                if key.contains("compilesdk") { out.append((.androidPlatform, kv.1)) }
                else if key.contains("ndk") { out.append((.androidNDK, kv.1)) }
                else if key.contains("buildtools") { out.append((.androidBuildTools, kv.1)) }
            }
            return out
        default:
            return []
        }
    }

    private static func asdfTool(_ name: String) -> Tool? {
        switch name.lowercased() {
        case "nodejs", "node": return .node
        case "python": return .python
        case "ruby": return .ruby
        case "java": return .java
        case "rust": return .rust
        case "golang", "go": return .go
        default: return nil
        }
    }

    /// `home = /path/to/python/bin` in a virtual environment's pyvenv.cfg, as the install folder.
    static func venvBase(_ env: URL) -> String? {
        guard let text = try? String(contentsOf: env.appendingPathComponent("pyvenv.cfg"), encoding: .utf8),
              let home = matches(#"(?m)^home\s*=\s*(.+)$"#, in: text).first?.trimmingCharacters(in: .whitespaces) else { return nil }
        return home.hasSuffix("/bin") ? String(home.dropLast(4)) : home
    }

    static func matches(_ pattern: String, in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        return re.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            $0.numberOfRanges > 1 ? Range($0.range(at: 1), in: text).map { String(text[$0]) } : nil
        }
    }

    private static func matchPairs(_ pattern: String, in text: String) -> [(String, String)] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        return re.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            guard $0.numberOfRanges > 2, let a = Range($0.range(at: 1), in: text), let b = Range($0.range(at: 2), in: text) else { return nil }
            return (String(text[a]), String(text[b]))
        }
    }
}
