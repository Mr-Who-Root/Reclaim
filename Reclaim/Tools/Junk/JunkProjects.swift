import Foundation

/// Finds rebuildable build output inside code projects (node_modules, target, build, Pods…).
/// A folder only counts when the project's own files say what it is (package.json next to node_modules,
/// Cargo.toml next to target, …), so a folder that merely happens to be called "build" is never listed.
enum JunkProjects {
    enum Kind { case build, environment }

    struct Artifact {
        let url: URL
        let project: String
        let label: String
        /// The command that brings the folder back (shown as is, never translated).
        let rebuild: String
        let kind: Kind
        /// Last activity in the project (git index, top-level files), not counting build output.
        let lastActivity: Date?
        var idleDays: Int { lastActivity.map { $0.daysAgo } ?? Int.max }
    }

    private struct Pattern {
        let markers: [String]
        let label: String
        let rebuild: String
        var kind: Kind = .build
        /// Matches when any child has this extension instead of a named marker file.
        var markerExtension: String? = nil
    }

    private static let js = ["package.json"]
    private static let gradle = ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"]
    private static let python = ["pyproject.toml", "requirements.txt", "setup.py", "setup.cfg", "Pipfile"]

    private static let patterns: [String: [Pattern]] = [
        "node_modules": [Pattern(markers: js, label: "npm packages", rebuild: "npm install")],
        ".next": [Pattern(markers: js, label: "Next.js build", rebuild: "npm run build")],
        ".nuxt": [Pattern(markers: js, label: "Nuxt build", rebuild: "npm run build")],
        ".svelte-kit": [Pattern(markers: js, label: "SvelteKit build", rebuild: "npm run build")],
        ".turbo": [Pattern(markers: js, label: "Turborepo cache", rebuild: "turbo build")],
        ".parcel-cache": [Pattern(markers: js, label: "Parcel cache", rebuild: "parcel build")],
        ".angular": [Pattern(markers: ["angular.json"], label: "Angular cache", rebuild: "ng build")],
        "target": [Pattern(markers: ["Cargo.toml"], label: "Rust build", rebuild: "cargo build"),
                   Pattern(markers: ["pom.xml"], label: "Maven build", rebuild: "mvn package")],
        "build": [Pattern(markers: gradle, label: "Gradle build", rebuild: "./gradlew build"),
                  Pattern(markers: ["pubspec.yaml"], label: "Flutter build", rebuild: "flutter build"),
                  Pattern(markers: ["CMakeLists.txt"], label: "CMake build", rebuild: "cmake --build")],
        ".gradle": [Pattern(markers: gradle, label: "Gradle project cache", rebuild: "./gradlew build")],
        ".dart_tool": [Pattern(markers: ["pubspec.yaml"], label: "Dart tool cache", rebuild: "flutter pub get")],
        "Pods": [Pattern(markers: ["Podfile"], label: "CocoaPods", rebuild: "pod install")],
        ".build": [Pattern(markers: ["Package.swift"], label: "Swift build", rebuild: "swift build")],
        "DerivedData": [Pattern(markers: [], label: "Xcode build", rebuild: "xcodebuild", markerExtension: "xcodeproj")],
        ".terraform": [Pattern(markers: [], label: "Terraform providers", rebuild: "terraform init", markerExtension: "tf")],
        ".tox": [Pattern(markers: python, label: "tox environments", rebuild: "tox")],
        ".pytest_cache": [Pattern(markers: python, label: "pytest cache", rebuild: "pytest")],
        ".mypy_cache": [Pattern(markers: python, label: "mypy cache", rebuild: "mypy")],
        ".ruff_cache": [Pattern(markers: python, label: "Ruff cache", rebuild: "ruff check")],
        ".venv": [Pattern(markers: python, label: "Python environment", rebuild: "pip install", kind: .environment)],
        "venv": [Pattern(markers: python, label: "Python environment", rebuild: "pip install", kind: .environment)],
    ]

    /// Folders where people keep code (the usual names plus any saved folders).
    static var roots: [URL] {
        rootURLs(saved: (UserDefaults.standard.stringArray(forKey: PrefKey.savedFolders) ?? []).map { URL(fileURLWithPath: $0, isDirectory: true) })
    }

    enum Bucket { case old, recent, environments }

    static func artifacts(_ bucket: Bucket) -> [Artifact] {
        artifacts(in: roots).filter { a in
            switch bucket {
            case .old: return a.kind == .build && a.idleDays >= 90
            case .recent: return a.kind == .build && a.idleDays >= 14 && a.idleDays < 90
            case .environments: return a.kind == .environment && a.idleDays >= 90
            }
        }
    }

    static func artifact(at url: URL) -> Artifact? {
        artifacts(in: roots).first { $0.url.path == url.path }
    }

    static func rootURLs(saved: [URL]) -> [URL] {
        let names = ["Github", "GitHub", "Developer", "Projects", "Code", "code", "src", "repos", "Repos", "workspace",
                     "Work", "dev", "Sites", "Documents/GitHub", "Documents/Projects", "AndroidStudioProjects", "StudioProjects"]
        var seen = Set<String>()
        var roots: [URL] = []
        for url in names.map({ FS.home.appendingPathComponent($0, isDirectory: true) }) + saved where FS.isDirectory(url) {
            let key = url.resolvingSymlinksInPath().path.lowercased()
            if seen.insert(key).inserted { roots.append(url) }
        }
        return roots
    }

    // One walk per scan, shared by the three project rules.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: (date: Date, roots: [String], artifacts: [Artifact])?

    static func artifacts(in roots: [URL]) -> [Artifact] {
        let key = roots.map(\.path)
        lock.lock()
        if let cache, cache.roots == key, Date().timeIntervalSince(cache.date) < 60 { lock.unlock(); return cache.artifacts }
        lock.unlock()
        let found = walk(roots)
        lock.lock(); cache = (.now, key, found); lock.unlock()
        return found
    }

    private static let skipNames: Set<String> = [".git", ".svn", ".hg", ".claude", ".idea", ".vscode", "Library", "Pods-src"]

    private static func walk(_ roots: [URL]) -> [Artifact] {
        var out: [Artifact] = []
        var budget = 250_000
        var queue: [(URL, Int, URL)] = roots.map { ($0, 0, $0) }
        var activityCache: [String: Date?] = [:]
        while !queue.isEmpty, budget > 0, !Task.isCancelled {
            let (dir, depth, devRoot) = queue.removeFirst()
            let children = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [])) ?? []
            budget -= children.count
            let names = Set(children.map(\.lastPathComponent))
            for child in children {
                let name = child.lastPathComponent
                guard let v = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                      v.isDirectory == true, v.isSymbolicLink != true else { continue }
                if let options = patterns[name] {
                    let match = options.first { p in
                        if let ext = p.markerExtension { return names.contains { $0.hasSuffix("." + ext) } }
                        return p.markers.contains(where: names.contains)
                    }
                    if let p = match {
                        let root = projectRoot(for: dir)
                        let activity = activityCache[root.path] ?? lastActivity(project: root, module: dir)
                        activityCache[root.path] = activity
                        let name: String
                        if FS.exists(root.appendingPathComponent(".git")) {
                            name = root.lastPathComponent + (dir.path == root.path ? "" : "/" + dir.path.dropFirst(root.path.count + 1))
                        } else {
                            // No repository: show where it sits inside the code folder.
                            name = dir.path.hasPrefix(devRoot.path + "/") ? String(dir.path.dropFirst(devRoot.path.count + 1)) : dir.lastPathComponent
                        }
                        out.append(Artifact(url: child, project: name, label: p.label,
                                            rebuild: p.rebuild, kind: p.kind, lastActivity: activity))
                        continue
                    }
                }
                if name.hasPrefix(".") || skipNames.contains(name) || name.hasSuffix(".app") || name.hasSuffix(".xcarchive") { continue }
                if depth < 6 { queue.append((child, depth + 1, devRoot)) }
            }
        }
        return out
    }

    /// The nearest folder above (or at) `dir` that has a .git, else `dir` itself.
    private static func projectRoot(for dir: URL) -> URL {
        var current = dir
        for _ in 0..<5 {
            if FS.exists(current.appendingPathComponent(".git")) { return current }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path || parent.path == FS.home.path { break }
            current = parent
        }
        return dir
    }

    /// Newest change to the project's own files: git's index and refs, and top-level files of the project and module.
    private static func lastActivity(project: URL, module: URL) -> Date? {
        var dates: [Date] = []
        let git = project.appendingPathComponent(".git")
        for f in ["index", "HEAD", "FETCH_HEAD", "ORIG_HEAD", "logs/HEAD"] {
            if let d = modified(git.appendingPathComponent(f)) { dates.append(d) }
        }
        for folder in Set([project.path, module.path]) {
            for child in FS.children(of: URL(fileURLWithPath: folder), includeHidden: false)
            where patterns[child.lastPathComponent] == nil && !FS.isDirectory(child) {
                if let d = modified(child) { dates.append(d) }
            }
        }
        return dates.max()
    }

    private static func modified(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}
