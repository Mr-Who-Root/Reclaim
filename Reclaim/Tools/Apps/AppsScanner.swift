import AppKit

/// An app bundle found in /Applications or ~/Applications.
struct InstalledApp: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    let bundleID: String?
    let version: String?
    /// Set for apps found outside the Applications folders (e.g. "~/Github/App/build/Release").
    var otherLocation: String? = nil
    var id: String { url.path }
}

/// A file or folder belonging to an app (or left behind by one).
struct AppSupportItem: Identifiable, Hashable, Sendable {
    let entry: FileEntry
    /// Library folder it lives in, e.g. "Caches".
    let location: String
    /// Matched only by the app's name (less certain than a bundle-identifier match).
    var byName = false
    var isAppBundle = false
    /// A folder macOS wouldn't let Reclaim read, so its size is unknown rather than zero.
    var unreadable = false
    var id: String { entry.id }

    init(entry: FileEntry, location: String, byName: Bool = false, isAppBundle: Bool = false) {
        self.entry = entry
        self.location = location
        self.byName = byName
        self.isAppBundle = isAppBundle
        self.unreadable = entry.isDirectory && !FS.canList(entry.url)
    }
}

/// Support files whose bundle identifier matches no installed app.
struct LeftoverGroup: Identifiable, Hashable, Sendable {
    let bundleID: String
    var items: [AppSupportItem]
    var id: String { bundleID.lowercased() }
    var size: Int64 { items.reduce(0) { $0 + $1.entry.size } }
}

/// File-system work for Apps & Leftovers. Everything here runs off the main thread.
enum AppsScanner {
    /// Library folders that hold per-app support files, with how entries are named there.
    struct Location: Sendable {
        let path: String
        let label: String
        /// Group-container style ids (TEAMID.com.x.y / group.com.x.y).
        var grouped = false
        /// Name matching (by app name) is meaningful here.
        var allowsNameMatch = false
    }

    static let locations: [Location] = [
        Location(path: "Application Support", label: "Application Support", allowsNameMatch: true),
        Location(path: "Caches", label: "Caches", allowsNameMatch: true),
        Location(path: "Containers", label: "Containers"),
        Location(path: "Group Containers", label: "Group Containers", grouped: true),
        Location(path: "Preferences", label: "Preferences"),
        Location(path: "Preferences/ByHost", label: "Preferences (ByHost)"),
        Location(path: "Saved Application State", label: "Saved Application State"),
        Location(path: "Logs", label: "Logs", allowsNameMatch: true),
        Location(path: "HTTPStorages", label: "HTTP Storage"),
        Location(path: "WebKit", label: "WebKit"),
        Location(path: "Cookies", label: "Cookies"),
        Location(path: "LaunchAgents", label: "Launch Agents"),
        Location(path: "Application Scripts", label: "Application Scripts", grouped: true),
    ]

    // MARK: Installed apps

    static func listApps() -> [InstalledApp] {
        let roots = [URL(fileURLWithPath: "/Applications", isDirectory: true),
                     FS.home.appendingPathComponent("Applications", isDirectory: true)]
        var found: [String: InstalledApp] = [:]
        for root in roots {
            for child in FS.children(of: root) {
                if child.pathExtension.lowercased() == "app" {
                    if let app = makeApp(child) { found[app.id] = app }
                } else if FS.isDirectory(child), !isSymlink(child) {
                    // One level of subfolders (Utilities, vendor folders like "Python 3.14").
                    for inner in FS.children(of: child) where inner.pathExtension.lowercased() == "app" {
                        if let app = makeApp(inner) { found[app.id] = app }
                    }
                }
            }
        }
        for url in AppLocator.appsOutsideApplications() where found[url.path] == nil {
            if var app = makeApp(url) {
                app.otherLocation = FS.abbreviate(url.deletingLastPathComponent().path)
                found[app.id] = app
            }
        }
        return found.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func isSymlink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
    }

    private static func makeApp(_ url: URL) -> InstalledApp? {
        // Symlinked apps (Safari points into a sealed system Cryptex) are either system apps or found elsewhere.
        if isSymlink(url) { return nil }
        let bundle = Bundle(url: url)
        let info = bundle?.infoDictionary ?? [:]
        let bundleID = bundle?.bundleIdentifier
        let name = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? url.deletingPathExtension().lastPathComponent
        let short = info["CFBundleShortVersionString"] as? String
        let build = info["CFBundleVersion"] as? String
        let version = short ?? build
        // Apple apps living on the sealed system volume can't be removed.
        if let bundleID, bundleID.hasPrefix("com.apple."), url.resolvingSymlinksInPath().path.hasPrefix("/System/") { return nil }
        return InstalledApp(url: url, name: name.isEmpty ? url.deletingPathExtension().lastPathComponent : name,
                            bundleID: bundleID, version: version)
    }

    // MARK: Support files for one app

    static func supportFiles(for app: InstalledApp) -> [AppSupportItem] {
        var items: [AppSupportItem] = []
        if let appEntry = FS.entry(for: app.url) {
            items.append(AppSupportItem(entry: appEntry, location: "Application", isAppBundle: true))
        }
        let bid = app.bundleID?.lowercased()
        let appName = app.name.lowercased()
        let fileName = app.url.deletingPathExtension().lastPathComponent.lowercased()
        let names = Set([appName, fileName].filter { $0.count >= 3 })
        var seen = Set<String>()

        for location in locations {
            if Task.isCancelled { break }
            let folder = FS.library(location.path)
            for child in FS.children(of: folder, includeHidden: false) {
                let raw = child.lastPathComponent
                let lower = raw.lowercased()
                var byName = false
                var matched = false
                if let bid {
                    let core = coreIdentifier(raw, location: location)?.lowercased()
                    if let core, core == bid || core.hasPrefix(bid + ".") {
                        matched = true
                    } else if location.path == "LaunchAgents", lower.contains(bid) {
                        matched = true
                    } else if location.grouped, lower.hasSuffix("." + bid) || lower.contains("." + bid + ".") {
                        matched = true
                    }
                }
                if !matched, location.allowsNameMatch, names.contains(lower) {
                    matched = true
                    byName = true
                }
                guard matched, seen.insert(child.path).inserted, let entry = FS.entry(for: child) else { continue }
                items.append(AppSupportItem(entry: entry, location: location.label, byName: byName))
            }
            // Vendor folders: "Google Chrome" keeps data in Application Support/Google/Chrome.
            if location.allowsNameMatch {
                let words = app.name.split(separator: " ")
                if words.count >= 2 {
                    let nested = folder.appendingPathComponent(String(words[0]), isDirectory: true)
                        .appendingPathComponent(words.dropFirst().joined(separator: " "), isDirectory: true)
                    if FS.isDirectory(nested), seen.insert(nested.path).inserted, let entry = FS.entry(for: nested) {
                        items.append(AppSupportItem(entry: entry, location: location.label, byName: true))
                    }
                }
            }
        }
        return items
    }

    // MARK: Identifier parsing

    private static let uuidPattern = try! NSRegularExpression(pattern: "^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$")
    private static let hexHostPattern = try! NSRegularExpression(pattern: "^[0-9A-Fa-f]{12}$")
    private static let bundleIDPattern = try! NSRegularExpression(pattern: "^[A-Za-z0-9][A-Za-z0-9-]*(\\.[A-Za-z0-9_-]+)+$")
    private static let teamPrefixPattern = try! NSRegularExpression(pattern: "^[A-Z0-9]{10}\\.")

    private static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    /// The bundle identifier an entry name refers to, or nil if it doesn't look like one.
    static func coreIdentifier(_ name: String, location: Location) -> String? {
        var s = name
        for suffix in [".plist", ".savedState", ".binarycookies"] where s.hasSuffix(suffix) {
            s = String(s.dropLast(suffix.count))
        }
        if location.path == "Preferences/ByHost" {
            // com.example.app.<hardware UUID>
            if let dot = s.lastIndex(of: ".") {
                let tail = String(s[s.index(after: dot)...])
                if matches(uuidPattern, tail) || matches(hexHostPattern, tail) { s = String(s[..<dot]) }
            }
        }
        var minDots = 2
        if location.grouped {
            // TEAMID.com.x.y, group.com.x.y, TEAMID.groups.com.x.y …
            if matches(teamPrefixPattern, s) { s = String(s.dropFirst(11)); minDots = 1 }
            for prefix in ["group.", "groups."] where s.hasPrefix(prefix) {
                s = String(s.dropFirst(prefix.count))
                minDots = 1
            }
        }
        guard !s.contains(" "), matches(bundleIDPattern, s), s.filter({ $0 == "." }).count >= minDots else { return nil }
        return s
    }

    /// Identifiers that belong to macOS, developer tools or shared frameworks rather than an app.
    private static let systemPrefixes = [
        "com.apple.", "apple.", "group.com.apple.", "systemgroup.", "org.swift.", "com.crashlytics", "io.fabric.",
        "com.plausiblelabs.", "io.sentry", "com.segment.", "org.sparkle-project.", "com.microsoft.appcenter",
        "org.python.", "org.nodejs.", "com.github.electron", "com.govindsr.reclaim", "org.chromium.crashpad",
        "com.google.firebase", "com.firebase", "is.workflow.", "org.cups.", "net.java.", "com.oracle.java", "main.kts",
        "com.telemetrydeck.",
    ]

    // MARK: Leftovers

    /// Finds support files whose identifier matches no installed or registered app.
    static func findLeftovers(installed: Set<String>, reporter: ProgressReporter) -> [LeftoverGroup] {
        let installedList = Array(installed)
        let vendors = Set(installed.compactMap(vendor(of:)))
        var lsCache: [String: Bool] = [:]

        func isInstalled(_ id: String) -> Bool {
            let c = id.lowercased()
            if systemPrefixes.contains(where: { c.hasPrefix($0) }) || c.hasPrefix("com.apple") { return true }
            if installed.contains(c) { return true }
            for i in installedList where c.hasPrefix(i + ".") || i.hasPrefix(c + ".") { return true }
            // Updaters, installers and shared groups from a developer whose app is still installed
            // (com.docker.install with Docker, com.google.Keystone with Chrome) belong to that app.
            if let v = vendor(of: c), vendors.contains(v) { return true }
            if let cached = lsCache[c] { return cached }
            let registered = !NSWorkspace.shared.urlsForApplications(withBundleIdentifier: id).isEmpty
            lsCache[c] = registered
            return registered
        }

        var groups: [String: LeftoverGroup] = [:]
        var checked = 0
        for location in locations {
            if Task.isCancelled { return [] }
            let folder = FS.library(location.path)
            reporter.report("Checking \(location.label)…")
            for child in FS.children(of: folder, includeHidden: false) {
                if Task.isCancelled { return [] }
                checked += 1
                guard let core = coreIdentifier(child.lastPathComponent, location: location) else { continue }
                if isInstalled(core) { continue }
                reporter.report("Measuring \(FS.abbreviate(child.path)) · \(checked.formatted()) entries checked")
                guard let entry = FS.entry(for: child) else { continue }
                let item = AppSupportItem(entry: entry, location: location.label)
                // Empty folders free nothing; leave them out (but keep protected ones, whose size is unknown).
                if entry.size == 0, !item.unreadable { continue }
                let key = core.lowercased()
                groups[key, default: LeftoverGroup(bundleID: core, items: [])].items.append(item)
            }
        }
        reporter.report("Checked \(checked.formatted()) entries", force: true)
        return groups.values
            .map { var g = $0; g.items.sort { $0.entry.size > $1.entry.size }; return g }
            .sorted { $0.size > $1.size }
    }

    /// "com.example" for "com.example.app.helper".
    static func vendor(of id: String) -> String? {
        let parts = id.lowercased().split(separator: ".")
        guard parts.count >= 2 else { return nil }
        return parts[0] + "." + parts[1]
    }

    // MARK: Finder fallback

    /// Asks Finder to move an item to the Trash (Finder prompts for an administrator password if needed).
    /// Runs `osascript` as a child process so the app stays responsive while the password sheet is up.
    /// Returns an error message, or nil on success.
    static func trashWithFinder(_ url: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e", "on run argv",
            "-e", "tell application \"Finder\" to delete (POSIX file (item 1 of argv) as alias)",
            "-e", "end run",
            url.path,
        ]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return error.localizedDescription
        }
        process.waitUntilExit()
        if process.terminationStatus == 0 { return nil }
        let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if message.contains("-128") { return "The password request was cancelled." }
        return message.isEmpty ? "Finder declined the request." : message
    }
}
