import SwiftUI
import AppKit

/// Sidebar-style groups that junk rules are listed under.
enum JunkGroup: String, CaseIterable, Identifiable {
    case appData = "App Caches & Logs"
    case browsers = "Browsers"
    case developer = "Developer"
    case backups = "Backups & Mail"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .appData: return "square.stack"
        case .browsers: return "globe"
        case .developer: return "hammer"
        case .backups: return "externaldrive"
        }
    }
}

enum JunkSafety {
    case safe, caution

    var label: String { self == .safe ? String(localized: "Safe") : String(localized: "Caution") }
    var color: Color { self == .safe ? .green : .orange }
}

/// Where a rule finds its items. Paths are relative to the home folder.
enum JunkSource {
    /// Every child of the folder is one item.
    case children(String)
    /// The path itself is one item.
    case path(String)
    /// Children of the folder with this extension.
    case childrenWithExtension(String, String)
    /// Children of the folder's subfolders with this extension (e.g. Archives/<date>/*.xcarchive).
    case grandchildrenWithExtension(String, String)
    /// `<child>/<sub>` for each child of the folder (e.g. Firefox Profiles/*/cache2).
    case profileSubfolder(String, String)
    /// Folders exactly this many levels below the folder (e.g. system-images/<api>/<tag>/<abi>).
    case descendants(String, Int)

    var base: URL {
        switch self {
        case .children(let p), .path(let p), .childrenWithExtension(let p, _),
             .grandchildrenWithExtension(let p, _), .profileSubfolder(let p, _), .descendants(let p, _):
            return FS.home.appendingPathComponent(p)
        }
    }
}

/// One kind of junk, with a plain explanation of why clearing it is safe.
struct JunkRule: Identifiable {
    let id: String
    let title: String
    let icon: String
    let explanation: String
    let group: JunkGroup
    let safety: JunkSafety
    let selectedByDefault: Bool
    var needsFullDiskAccess = false
    let sources: [JunkSource]
    /// Child names never listed by this rule.
    var excludedNames: Set<String> = []
    /// The generic app-caches rule skips anything another rule already owns.
    var isAppCaches = false

    /// Pre-selected after a scan, and counted as reclaimable.
    var isRecommended: Bool { selectedByDefault && safety == .safe }
}

enum JunkRules {
    /// Virtual machine folders. UTM keeps its VMs in its container, which is only read with Full Disk Access
    /// (otherwise macOS would ask about "data from other apps" in the middle of a scan).
    private static var vmSources: [JunkSource] {
        var sources: [JunkSource] = [
            .childrenWithExtension("Parallels", "pvm"),
            .childrenWithExtension("Virtual Machines.localized", "vmwarevm"),
            .childrenWithExtension("Virtual Machines", "vmwarevm"),
            .children("VirtualBox VMs"),
            .children(".tart/vms"),
            .children(".lima"),
        ]
        if FS.hasFullDiskAccess() {
            sources.append(.childrenWithExtension("Library/Containers/com.utmapp.UTM/Data/Documents", "utm"))
        }
        return sources
    }

    static var all: [JunkRule] { [
        // MARK: App caches & logs
        JunkRule(
            id: "appCaches", title: String(localized: "App caches"), icon: "internaldrive",
            explanation: String(localized: "Files apps keep so they load faster. Apps rebuild them as needed, so clearing them is safe — an app may feel a little slower the first time you open it."),
            group: .appData, safety: .safe, selectedByDefault: true,
            sources: [.children("Library/Caches")],
            excludedNames: [
                "com.govindsr.reclaim", "CloudKit", "com.apple.bird", "com.apple.nsurlsessiond", "com.apple.akd",
                "FamilyCircle", "com.apple.homed", "com.apple.HomeKit", "com.apple.findmy.fmipcore",
                "com.apple.ap.adprivacyd", "com.apple.containermanagerd",
            ],
            isAppCaches: true),
        JunkRule(
            id: "appLogs", title: String(localized: "App logs"), icon: "doc.plaintext",
            explanation: String(localized: "Diagnostic text files apps write over time, including old crash reports. Nothing needs them to run, and apps start fresh logs automatically."),
            group: .appData, safety: .safe, selectedByDefault: true,
            sources: [.children("Library/Logs")]),
        JunkRule(
            id: "savedState", title: String(localized: "Saved window state"), icon: "macwindow",
            explanation: String(localized: "What apps remember about their open windows between launches. Clearing it only means some apps reopen with their default windows."),
            group: .appData, safety: .safe, selectedByDefault: true,
            sources: [.children("Library/Saved Application State")],
            excludedNames: ["com.govindsr.reclaim.savedState"]),

        // MARK: Browsers
        JunkRule(
            id: "chromium", title: String(localized: "Chrome-family browser caches"), icon: "globe",
            explanation: String(localized: "Chrome, Brave, Edge, Vivaldi and Arc rebuild their caches as you browse. Sites may load a little slower on the first visit. History, passwords and tabs aren't touched."),
            group: .browsers, safety: .safe, selectedByDefault: true,
            sources: [
                .path("Library/Caches/Google/Chrome"), .path("Library/Caches/Google/Chrome Canary"),
                .path("Library/Caches/Chromium"), .path("Library/Caches/BraveSoftware/Brave-Browser"),
                .path("Library/Caches/Microsoft Edge"), .path("Library/Caches/Vivaldi"),
                .path("Library/Caches/Arc"), .path("Library/Caches/company.thebrowser.Browser"),
            ]),
        JunkRule(
            id: "firefox", title: String(localized: "Firefox cache"), icon: "flame",
            explanation: String(localized: "Firefox rebuilds its cache as you browse. Sites may load a little slower on the first visit. Bookmarks, history and passwords aren't touched."),
            group: .browsers, safety: .safe, selectedByDefault: true,
            sources: [.profileSubfolder("Library/Caches/Firefox/Profiles", "cache2")]),

        // MARK: Developer
        JunkRule(
            id: "derivedData", title: String(localized: "Xcode DerivedData"), icon: "hammer",
            explanation: String(localized: "Build intermediates and indexes that Xcode fully rebuilds on the next build. The classic developer space hog — your projects and code aren't stored here."),
            group: .developer, safety: .safe, selectedByDefault: true,
            sources: [.children("Library/Developer/Xcode/DerivedData")]),
        JunkRule(
            id: "deviceSupport", title: String(localized: "Device support files"), icon: "iphone",
            explanation: String(localized: "Debugging symbols Xcode copied from iPhones, Watches and Apple TVs you've connected. Xcode copies them again the next time you connect that device."),
            group: .developer, safety: .safe, selectedByDefault: true,
            sources: [
                .children("Library/Developer/Xcode/iOS DeviceSupport"),
                .children("Library/Developer/Xcode/watchOS DeviceSupport"),
                .children("Library/Developer/Xcode/tvOS DeviceSupport"),
                .children("Library/Developer/Xcode/visionOS DeviceSupport"),
            ]),
        JunkRule(
            id: "simCaches", title: String(localized: "Simulator caches"), icon: "ipad.and.iphone",
            explanation: String(localized: "Caches Simulator recreates on demand. Your simulated devices and the apps installed on them are kept."),
            group: .developer, safety: .safe, selectedByDefault: true,
            sources: [.children("Library/Developer/CoreSimulator/Caches")]),
        JunkRule(
            id: "previews", title: String(localized: "SwiftUI preview data"), icon: "rectangle.on.rectangle",
            explanation: String(localized: "Builds Xcode makes for SwiftUI previews. They're regenerated the next time you open a preview."),
            group: .developer, safety: .safe, selectedByDefault: true,
            sources: [.children("Library/Developer/Xcode/UserData/Previews")]),
        JunkRule(
            id: "archives", title: String(localized: "Xcode archives"), icon: "archivebox",
            explanation: String(localized: "Your distributable app builds, with debug symbols. Keep any you may still need to symbolicate crash reports or submit again."),
            group: .developer, safety: .caution, selectedByDefault: false,
            sources: [.grandchildrenWithExtension("Library/Developer/Xcode/Archives", "xcarchive")]),
        JunkRule(
            id: "npm", title: String(localized: "npm cache"), icon: "shippingbox",
            explanation: String(localized: "Package tarballs npm downloaded. npm fetches them again when a project needs them."),
            group: .developer, safety: .safe, selectedByDefault: true,
            sources: [.path(".npm/_cacache")]),
        JunkRule(
            id: "yarn", title: String(localized: "Yarn cache"), icon: "shippingbox",
            explanation: String(localized: "Yarn's offline package cache. Packages download again on the next install."),
            group: .developer, safety: .safe, selectedByDefault: true,
            sources: [.path("Library/Caches/Yarn")]),
        JunkRule(
            id: "pip", title: String(localized: "pip cache"), icon: "shippingbox",
            explanation: String(localized: "Python packages pip downloaded or built. pip fetches them again when needed."),
            group: .developer, safety: .safe, selectedByDefault: true,
            sources: [.path("Library/Caches/pip")]),
        JunkRule(
            id: "homebrew", title: String(localized: "Homebrew downloads"), icon: "mug",
            explanation: String(localized: "Bottles and source archives Homebrew downloaded during installs and upgrades. Installed packages keep working."),
            group: .developer, safety: .safe, selectedByDefault: true,
            sources: [.path("Library/Caches/Homebrew")]),
        JunkRule(
            id: "cocoapods", title: String(localized: "CocoaPods cache"), icon: "shippingbox",
            explanation: String(localized: "Pod specs and downloads CocoaPods keeps between installs. They download again on the next `pod install`."),
            group: .developer, safety: .safe, selectedByDefault: true,
            sources: [.path("Library/Caches/CocoaPods")]),
        JunkRule(
            id: "gradle", title: String(localized: "Gradle caches"), icon: "cube",
            explanation: String(localized: "Downloaded dependencies, build caches and wrapper distributions for Gradle (Android and Java). Rebuilt on your next build."),
            group: .developer, safety: .safe, selectedByDefault: true,
            sources: [.path(".gradle/caches"), .children(".gradle/wrapper/dists")]),
        JunkRule(
            id: "cargo", title: String(localized: "Cargo registry cache"), icon: "shippingbox",
            explanation: String(localized: "Crate archives Cargo downloaded. Rust projects download them again when needed."),
            group: .developer, safety: .safe, selectedByDefault: true,
            sources: [.path(".cargo/registry/cache")]),
        JunkRule(
            id: "android", title: String(localized: "Android emulator images"), icon: "candybarphone",
            explanation: String(localized: "Virtual device disks, often several gigabytes each. Removing one deletes that emulator and its data — recreate it in Android Studio if you need it again."),
            group: .developer, safety: .caution, selectedByDefault: false,
            sources: [.childrenWithExtension(".android/avd", "avd")]),
        JunkRule(
            id: "androidSnapshots", title: String(localized: "Android emulator snapshots"), icon: "camera.viewfinder",
            explanation: String(localized: "Quick Boot snapshots of your Android emulators. Removing them only means the next start is a cold boot — the emulators and their data are kept."),
            group: .developer, safety: .safe, selectedByDefault: true,
            sources: [.profileSubfolder(".android/avd", "snapshots")]),
        JunkRule(
            id: "androidImages", title: String(localized: "Android system images"), icon: "cpu",
            explanation: String(localized: "The Android OS images emulators are created from, often several gigabytes each. Android Studio downloads one again when you create an emulator that needs it."),
            group: .developer, safety: .caution, selectedByDefault: false,
            sources: [.descendants("Library/Android/sdk/system-images", 3)]),
        JunkRule(
            id: "androidCaches", title: String(localized: "Android tool caches"), icon: "shippingbox",
            explanation: String(localized: "Caches the Android build tools and emulator rebuild on demand."),
            group: .developer, safety: .safe, selectedByDefault: true,
            sources: [.path(".android/cache"), .path(".android/build-cache")]),
        JunkRule(
            id: "simUnavailable", title: String(localized: "Unavailable simulators"), icon: "iphone.slash",
            explanation: String(localized: "Simulated devices whose iOS, watchOS, tvOS or visionOS version is no longer installed, so Xcode can't run them. The same as xcrun simctl delete unavailable."),
            group: .developer, safety: .safe, selectedByDefault: true,
            sources: [.children("Library/Developer/CoreSimulator/Devices")]),
        JunkRule(
            id: "simDevices", title: String(localized: "Simulator devices"), icon: "ipad.and.iphone",
            explanation: String(localized: "Simulated iPhones, iPads, Watches, Apple TVs and Vision Pros with the apps and data on them. Xcode can create a device again, but its data is gone. Running simulators are left alone."),
            group: .developer, safety: .caution, selectedByDefault: false,
            sources: [.children("Library/Developer/CoreSimulator/Devices")]),
        JunkRule(
            id: "genymotion", title: String(localized: "Genymotion virtual devices"), icon: "candybarphone",
            explanation: String(localized: "Android virtual devices deployed by Genymotion. Removing one deletes that device and its data."),
            group: .developer, safety: .caution, selectedByDefault: false,
            sources: [.children(".Genymobile/Genymotion/deployed")]),
        JunkRule(
            id: "vms", title: String(localized: "Virtual machines"), icon: "desktopcomputer",
            explanation: String(localized: "Virtual machines from Parallels, VMware Fusion, VirtualBox, UTM, Tart and Lima — often tens of gigabytes each. Removing one deletes that machine and everything inside it."),
            group: .developer, safety: .caution, selectedByDefault: false,
            sources: vmSources, excludedNames: ["_config", "_cache", "_disks", "_networks"]),

        // MARK: Backups & Mail
        JunkRule(
            id: "iosBackups", title: String(localized: "iPhone & iPad backups"), icon: "iphone.gen3",
            explanation: String(localized: "Full device backups made by syncing with this Mac. Remove one only if that device backs up to iCloud or you no longer own it."),
            group: .backups, safety: .caution, selectedByDefault: false, needsFullDiskAccess: true,
            sources: [.children("Library/Application Support/MobileSync/Backup")]),
        JunkRule(
            id: "mailDownloads", title: String(localized: "Mail attachment copies"), icon: "paperclip",
            explanation: String(localized: "Copies of attachments you opened from Mail. The originals stay in your messages."),
            group: .backups, safety: .safe, selectedByDefault: true, needsFullDiskAccess: true,
            sources: [.children("Library/Containers/com.apple.mail/Data/Library/Mail Downloads")]),
    ] }
}

/// One removable thing found by a rule.
struct JunkItem: Identifiable, Hashable {
    let entry: FileEntry
    var detail: String?
    /// Small files that belong with this item and go to the Trash with it (e.g. an emulator's .ini).
    var companions: [URL] = []
    var id: String { entry.id }
}

struct JunkRuleResult: Identifiable {
    let rule: JunkRule
    var items: [JunkItem]
    var id: String { rule.id }
    var bytes: Int64 { items.reduce(0) { $0 + $1.entry.size } }
}

struct JunkScanOutput {
    var results: [JunkRuleResult] = []
    /// Titles of rules that need Full Disk Access to be read.
    var blockedRules: [String] = []
}

/// Synchronous scanner; run it from a background task. Checks `Task.isCancelled`.
enum JunkScanner {
    static func run(rules: [JunkRule], reporter: ProgressReporter) -> JunkScanOutput {
        var output = JunkScanOutput()
        let owned = ownedPaths(rules)
        var appNames: [String: String?] = [:]

        for rule in rules {
            if Task.isCancelled { break }
            reporter.report("Checking \(rule.title.lowercased())…", force: true)
            let (urls, unreadable) = locate(rule, owned: owned)
            if unreadable, rule.needsFullDiskAccess { output.blockedRules.append(rule.title) }

            var items: [JunkItem] = []
            for url in urls {
                if Task.isCancelled { break }
                reporter.report("\(rule.title): \(url.lastPathComponent)")
                guard let entry = FS.entry(for: url), entry.size > 0 else { continue }
                items.append(JunkItem(entry: entry,
                                      detail: detail(for: rule, url: url, appNames: &appNames),
                                      companions: companions(for: rule, url: url)))
            }
            if !items.isEmpty {
                items.sort { $0.entry.size > $1.entry.size }
                output.results.append(JunkRuleResult(rule: rule, items: items))
            }
        }
        return output
    }

    /// Folders owned by specific rules, so the generic app-caches rule doesn't list them twice.
    private static func ownedPaths(_ rules: [JunkRule]) -> [String] {
        rules.filter { !$0.isAppCaches }.flatMap { $0.sources.map { $0.base.standardizedFileURL.path } }
    }

    private static func isOwned(_ path: String, by owned: [String]) -> Bool {
        owned.contains { o in o == path || o.hasPrefix(path + "/") || path.hasPrefix(o + "/") }
    }

    /// Returns candidate URLs, and whether a source folder exists but couldn't be listed.
    private static func locate(_ rule: JunkRule, owned: [String]) -> ([URL], Bool) {
        var urls: [URL] = []
        var unreadable = false

        func list(_ base: URL) -> [URL]? {
            guard FS.exists(base) else { return [] }
            guard FS.canList(base) else { unreadable = true; return nil }
            return FS.children(of: base)
        }

        for source in rule.sources {
            let base = source.base
            switch source {
            case .path:
                if FS.exists(base) { urls.append(base) }
            case .children:
                urls += list(base) ?? []
            case .childrenWithExtension(_, let ext):
                urls += (list(base) ?? []).filter { $0.pathExtension.lowercased() == ext }
            case .grandchildrenWithExtension(_, let ext):
                for child in list(base) ?? [] where FS.isDirectory(child) {
                    urls += FS.children(of: child).filter { $0.pathExtension.lowercased() == ext }
                }
            case .profileSubfolder(_, let sub):
                for child in list(base) ?? [] {
                    let candidate = child.appendingPathComponent(sub)
                    if FS.exists(candidate) { urls.append(candidate) }
                }
            case .descendants(_, let depth):
                var level = (list(base) ?? []).filter(FS.isDirectory)
                for _ in 1..<max(1, depth) {
                    level = level.flatMap { FS.children(of: $0).filter(FS.isDirectory) }
                }
                urls += level
            }
        }

        if rule.id == "simUnavailable" || rule.id == "simDevices" {
            let sims = SimulatorInfo.shared
            urls = urls.filter { url in
                guard FS.isDirectory(url), let info = sims[url.lastPathComponent], !info.booted else { return false }
                return rule.id == "simUnavailable" ? !info.available : info.available
            }
        }

        urls = urls.filter { !rule.excludedNames.contains($0.lastPathComponent) }
        if rule.isAppCaches {
            urls = urls.filter { !isOwned($0.standardizedFileURL.path, by: owned) }
        }
        return (urls, unreadable)
    }

    /// Simulator devices by UDID, read once per scan from `simctl` (or each device.plist if Xcode isn't selected).
    private enum SimulatorInfo {
        struct Device { let name: String; let runtime: String; let available: Bool; let booted: Bool; let lastBooted: Date? }
        static var shared: [String: Device] { load() }

        private static var cache: (date: Date, devices: [String: Device])?

        static func load() -> [String: Device] {
            if let cache, Date().timeIntervalSince(cache.date) < 30 { return cache.devices }
            let devices = fromSimctl() ?? fromPlists()
            cache = (.now, devices)
            return devices
        }

        /// Runs `xcrun simctl` only when developer tools are selected, so it never triggers the install prompt.
        private static func fromSimctl() -> [String: Device]? {
            let select = Process()
            select.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
            select.arguments = ["-p"]
            select.standardOutput = Pipe(); select.standardError = Pipe()
            guard (try? select.run()) != nil else { return nil }
            select.waitUntilExit()
            guard select.terminationStatus == 0 else { return nil }

            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            p.arguments = ["simctl", "list", "devices", "-j"]
            let out = Pipe()
            p.standardOutput = out; p.standardError = Pipe()
            guard (try? p.run()) != nil else { return nil }
            let watchdog = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: watchdog)
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            watchdog.cancel()
            guard p.terminationStatus == 0,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let byRuntime = json["devices"] as? [String: [[String: Any]]] else { return nil }
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var result: [String: Device] = [:]
            for (runtime, list) in byRuntime {
                for d in list {
                    guard let udid = d["udid"] as? String else { continue }
                    let last = (d["lastBootedAt"] as? String).flatMap { iso.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) }
                    result[udid] = Device(name: d["name"] as? String ?? udid, runtime: runtime,
                                          available: d["isAvailable"] as? Bool ?? true,
                                          booted: (d["state"] as? String) == "Booted", lastBooted: last)
                }
            }
            return result
        }

        /// Without simctl we can't tell whether a runtime is installed, so every device counts as available.
        private static func fromPlists() -> [String: Device] {
            var result: [String: Device] = [:]
            for dir in FS.children(of: FS.library("Developer/CoreSimulator/Devices")) where FS.isDirectory(dir) {
                guard let data = try? Data(contentsOf: dir.appendingPathComponent("device.plist")),
                      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { continue }
                result[dir.lastPathComponent] = Device(name: plist["name"] as? String ?? dir.lastPathComponent,
                                                       runtime: plist["runtime"] as? String ?? "",
                                                       available: true, booted: (plist["state"] as? Int) == 3, lastBooted: nil)
            }
            return result
        }

        /// "com.apple.CoreSimulator.SimRuntime.iOS-18-2" → "iOS 18.2"
        static func pretty(_ runtime: String) -> String {
            guard let last = runtime.split(separator: ".").last else { return runtime }
            let parts = last.split(separator: "-")
            guard let os = parts.first else { return String(last) }
            return parts.count > 1 ? "\(os) \(parts.dropFirst().joined(separator: "."))" : String(os)
        }
    }

    private static func companions(for rule: JunkRule, url: URL) -> [URL] {
        guard rule.id == "android" else { return [] }
        let ini = url.deletingPathExtension().appendingPathExtension("ini")
        return FS.exists(ini) ? [ini] : []
    }

    // MARK: Item details

    private static func detail(for rule: JunkRule, url: URL, appNames: inout [String: String?]) -> String? {
        let name = url.lastPathComponent
        switch rule.id {
        case "appCaches":
            return appName(forBundleID: name, cache: &appNames).map { "Cache for \($0)" }
        case "appLogs":
            return appName(forBundleID: name, cache: &appNames).map { "Logs from \($0)" }
        case "savedState":
            let id = name.replacingOccurrences(of: ".savedState", with: "")
            return appName(forBundleID: id, cache: &appNames).map { "Windows of \($0)" }
        case "derivedData":
            let info = plist(url.appendingPathComponent("info.plist"))
            if let workspace = info?["WorkspacePath"] as? String {
                var text = "Build data for \(FS.abbreviate(workspace))"
                if let used = info?["LastAccessedDate"] as? Date { text += " · last built \(Fmt.relative(used))" }
                return text
            }
            // Folders are named "<Project>-<hash>".
            if let dash = name.lastIndex(of: "-"), dash != name.startIndex {
                return "Build data for \(name[..<dash])"
            }
            return nil
        case "archives":
            let info = plist(url.appendingPathComponent("Info.plist"))
            let appName = info?["Name"] as? String ?? url.deletingPathExtension().lastPathComponent
            let props = info?["ApplicationProperties"] as? [String: Any]
            let version = props?["CFBundleShortVersionString"] as? String
            let created = info?["CreationDate"] as? Date
            return [appName + (version.map { " \($0)" } ?? ""), created.map { "archived \(Fmt.date($0))" }]
                .compactMap { $0 }.joined(separator: " · ")
        case "deviceSupport":
            return "Symbols for \(name)"
        case "iosBackups":
            let info = plist(url.appendingPathComponent("Info.plist"))
            let device = info?["Device Name"] as? String
            let product = info?["Product Name"] as? String
            let last = info?["Last Backup Date"] as? Date
            let parts = [device, product, last.map { "backed up \(Fmt.date($0))" }].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        case "android":
            return String(localized: "Emulator \(url.deletingPathExtension().lastPathComponent)")
        case "androidSnapshots":
            return String(localized: "Quick Boot snapshots of \(url.deletingLastPathComponent().deletingPathExtension().lastPathComponent)")
        case "androidImages":
            // system-images/<android-35>/<google_apis_playstore>/<arm64-v8a>
            let abi = url.lastPathComponent
            let tag = url.deletingLastPathComponent().lastPathComponent.replacingOccurrences(of: "_", with: " ")
            let api = url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
                .replacingOccurrences(of: "android-", with: "API ")
            return "\(api) · \(tag) · \(abi)"
        case "simUnavailable", "simDevices":
            guard let info = SimulatorInfo.shared[name] else { return nil }
            var parts = [info.name, SimulatorInfo.pretty(info.runtime)]
            if let last = info.lastBooted { parts.append(String(localized: "last used \(Fmt.relative(last))")) }
            else if rule.id == "simDevices" { parts.append(String(localized: "never booted")) }
            return parts.joined(separator: " · ")
        case "vms", "genymotion":
            return url.deletingPathExtension().lastPathComponent
        default:
            return nil
        }
    }

    private static func plist(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    /// Display name of the app with this bundle id, if it looks like one and is installed.
    private static func appName(forBundleID id: String, cache: inout [String: String?]) -> String? {
        if let hit = cache[id] { return hit }
        var result: String?
        if id.split(separator: ".").count >= 3,
           let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            result = FileManager.default.displayName(atPath: appURL.path).replacingOccurrences(of: ".app", with: "")
        }
        cache[id] = result
        return result
    }
}
