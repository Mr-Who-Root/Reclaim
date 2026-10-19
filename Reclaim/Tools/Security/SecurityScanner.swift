import Foundation
import Darwin

/// One installed app and its signature.
struct SecurityAppItem: Identifiable, Hashable {
    let url: URL
    let name: String
    let version: String?
    let bundleID: String?
    var signature: SecuritySignatureInfo

    var id: String { url.path }
    var needsAttention: Bool { signature.status.severity == .attention }
}

/// A launch agent or daemon plist and the program it starts.
struct SecurityLaunchItem: Identifiable, Hashable {
    enum Scope: Int, CaseIterable, Comparable {
        case user, allUsers, system
        static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
        var title: String {
            switch self {
            case .user: return "Starts when you log in"
            case .allUsers: return "Starts for every user"
            case .system: return "Starts with the system"
            }
        }
        var folder: String {
            switch self {
            case .user: return "~/Library/LaunchAgents"
            case .allUsers: return "/Library/LaunchAgents"
            case .system: return "/Library/LaunchDaemons"
            }
        }
    }

    let plistURL: URL
    let label: String
    let scope: Scope
    /// Absolute path of the executable it launches, if the plist names one.
    let program: String?
    let arguments: [String]
    let runAtLoad: Bool
    let keepAlive: Bool
    let disabled: Bool
    let programExists: Bool
    /// The app or binary whose signature was read.
    let target: URL?
    let signature: SecuritySignatureInfo?

    var id: String { plistURL.path }

    var isOrphaned: Bool { program != nil && !programExists }

    var needsAttention: Bool {
        isOrphaned || signature?.status.severity == .attention
    }

    var whenText: String {
        var parts: [String] = []
        if runAtLoad { parts.append("runs at load") }
        if keepAlive { parts.append("kept alive") }
        if disabled { parts.append("disabled") }
        return parts.isEmpty ? "on demand" : parts.joined(separator: " · ")
    }
}

/// A file in Downloads and the record macOS kept about where it came from.
struct SecurityDownloadOrigin: Identifiable, Hashable {
    let url: URL
    let size: Int64
    let modified: Date?
    /// App that downloaded it (from the quarantine record).
    let agent: String?
    /// When it was downloaded (from the quarantine record).
    let downloaded: Date?
    let source: URL?
    let referrer: URL?
    let quarantined: Bool

    var id: String { url.path }
    var name: String { url.lastPathComponent }

    var domain: String? {
        (source?.host ?? referrer?.host).map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }
    }

    var hasRecord: Bool { quarantined || source != nil }

    var summary: String {
        guard hasRecord else { return "No download record. It may have been copied, created here, or downloaded by a tool that doesn't tag files." }
        var text = "Downloaded"
        if let agent { text += " by \(agent)" }
        if let downloaded { text += " on \(Fmt.date(downloaded))" }
        if let domain { text += " from \(domain)" }
        return text
    }
}

struct SecurityScanResult {
    var apps: [SecurityAppItem] = []
    var launchItems: [SecurityLaunchItem] = []
    var origins: [SecurityDownloadOrigin] = []
}

/// Read-only collection of everything Security Check shows. Synchronous; run off the main thread.
enum SecurityScanner {
    static func run(progress: ProgressReporter) -> SecurityScanResult {
        var result = SecurityScanResult()
        let appURLs = findApps()
        for (i, url) in appURLs.enumerated() {
            if Task.isCancelled { return result }
            progress.report("Reading signatures — \(url.deletingPathExtension().lastPathComponent) (\(i + 1) of \(appURLs.count))")
            result.apps.append(appItem(url, deep: false))
        }
        if Task.isCancelled { return result }
        progress.report("Checking what starts by itself…", force: true)
        result.launchItems = launchItems()
        if Task.isCancelled { return result }
        progress.report("Reading download records…", force: true)
        result.origins = downloadOrigins()
        return result
    }

    // MARK: Apps

    static func findApps() -> [URL] {
        let fm = FileManager.default
        let roots = [URL(fileURLWithPath: "/Applications", isDirectory: true),
                     FS.home.appendingPathComponent("Applications", isDirectory: true)]
        var seen = Set<String>()
        var apps: [URL] = []

        func consider(_ url: URL) {
            let resolved = url.resolvingSymlinksInPath()
            // Skip dangling symlinks (an alias to an app that was removed has no code to check).
            guard resolved.pathExtension.lowercased() == "app", fm.fileExists(atPath: resolved.path),
                  seen.insert(resolved.path).inserted else { return }
            apps.append(resolved)
        }

        for root in roots {
            guard let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
            for item in items {
                if item.pathExtension.lowercased() == "app" {
                    consider(item)
                } else if FS.isDirectory(item) {
                    // One level of subfolders (Utilities, vendor folders).
                    let inner = (try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
                    for child in inner where child.pathExtension.lowercased() == "app" { consider(child) }
                }
            }
        }
        return apps.sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
    }

    static func appItem(_ url: URL, deep: Bool) -> SecurityAppItem {
        let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")) as? [String: Any] ?? [:]
        // The Finder name, falling back to the bundle's own name.
        let fileName = url.deletingPathExtension().lastPathComponent
        let name = fileName.isEmpty ? ((info["CFBundleName"] as? String) ?? url.lastPathComponent) : fileName
        let version = (info["CFBundleShortVersionString"] as? String) ?? (info["CFBundleVersion"] as? String)
        return SecurityAppItem(url: url, name: name,
                               version: version, bundleID: info["CFBundleIdentifier"] as? String,
                               signature: SecuritySignatureReader.check(url, deep: deep))
    }

    // MARK: Launch agents & daemons

    static func launchItems() -> [SecurityLaunchItem] {
        let folders: [(URL, SecurityLaunchItem.Scope)] = [
            (FS.library("LaunchAgents"), .user),
            (URL(fileURLWithPath: "/Library/LaunchAgents", isDirectory: true), .allUsers),
            (URL(fileURLWithPath: "/Library/LaunchDaemons", isDirectory: true), .system),
        ]
        var items: [SecurityLaunchItem] = []
        var signatureCache: [String: SecuritySignatureInfo] = [:]
        for (folder, scope) in folders {
            let plists = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            for plist in plists where plist.pathExtension.lowercased() == "plist" {
                if Task.isCancelled { return items }
                guard let dict = NSDictionary(contentsOf: plist) as? [String: Any] else { continue }
                let label = (dict["Label"] as? String) ?? plist.deletingPathExtension().lastPathComponent
                let args = (dict["ProgramArguments"] as? [String]) ?? []
                var program = (dict["Program"] as? String) ?? args.first
                if let p = program, p.hasPrefix("~") { program = (p as NSString).expandingTildeInPath }
                if let p = program, !p.hasPrefix("/") { program = nil } // relative names are resolved by launchd's PATH; we can't check them
                let exists = program.map { FileManager.default.fileExists(atPath: $0) } ?? false
                let keepAlive: Bool = {
                    if let b = dict["KeepAlive"] as? Bool { return b }
                    return dict["KeepAlive"] is [String: Any]
                }()

                var target: URL?
                var signature: SecuritySignatureInfo?
                if let program, exists {
                    let t = SecuritySignatureReader.enclosingApp(of: program) ?? URL(fileURLWithPath: program)
                    target = t
                    if let cached = signatureCache[t.path] {
                        signature = cached
                    } else {
                        let s = SecuritySignatureReader.check(t, deep: false)
                        signatureCache[t.path] = s
                        signature = s
                    }
                }
                items.append(SecurityLaunchItem(plistURL: plist, label: label, scope: scope, program: program,
                                                arguments: Array(args.dropFirst()), runAtLoad: dict["RunAtLoad"] as? Bool ?? false,
                                                keepAlive: keepAlive, disabled: dict["Disabled"] as? Bool ?? false,
                                                programExists: exists, target: target, signature: signature))
            }
        }
        return items.sorted {
            if $0.needsAttention != $1.needsAttention { return $0.needsAttention }
            if $0.scope != $1.scope { return $0.scope < $1.scope }
            return $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
        }
    }

    // MARK: Download origins

    static func downloadOrigins() -> [SecurityDownloadOrigin] {
        let items = (try? FileManager.default.contentsOfDirectory(at: FS.downloads, includingPropertiesForKeys: FS.resourceKeys, options: [.skipsHiddenFiles])) ?? []
        var origins: [SecurityDownloadOrigin] = []
        for url in items {
            if Task.isCancelled { break }
            let values = try? url.resourceValues(forKeys: FS.resourceKeySet)
            let quarantine = readQuarantine(url.path)
            let froms = readWhereFroms(url.path)
            let size = values.map { $0.isDirectory == true ? 0 : FS.allocated($0) } ?? 0
            origins.append(SecurityDownloadOrigin(url: url, size: size, modified: values?.contentModificationDate,
                                                  agent: quarantine?.agent, downloaded: quarantine?.date,
                                                  source: froms.first.flatMap(URL.init(string:)),
                                                  referrer: froms.dropFirst().first.flatMap(URL.init(string:)),
                                                  quarantined: quarantine != nil))
        }
        return origins.sorted { ($0.downloaded ?? $0.modified ?? .distantPast) > ($1.downloaded ?? $1.modified ?? .distantPast) }
    }

    private static func xattr(_ path: String, _ name: String) -> Data? {
        let size = getxattr(path, name, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, size, 0, 0) }
        guard read > 0 else { return nil }
        return data.prefix(read)
    }

    /// `com.apple.quarantine` is "flags;hex-timestamp;agent;uuid".
    static func readQuarantine(_ path: String) -> (agent: String?, date: Date?)? {
        guard let data = xattr(path, "com.apple.quarantine"), let text = String(data: data, encoding: .utf8) else { return nil }
        let parts = text.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        var date: Date?
        if parts.count > 1, let seconds = UInt64(parts[1], radix: 16), seconds > 0 {
            date = Date(timeIntervalSince1970: TimeInterval(seconds))
        }
        let agent = parts.count > 2 && !parts[2].isEmpty ? parts[2] : nil
        return (agent, date)
    }

    /// `com.apple.metadata:kMDItemWhereFroms` is a binary plist array: [source URL, referrer].
    static func readWhereFroms(_ path: String) -> [String] {
        guard let data = xattr(path, "com.apple.metadata:kMDItemWhereFroms"),
              let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String] else { return [] }
        return list.filter { !$0.isEmpty }
    }
}
