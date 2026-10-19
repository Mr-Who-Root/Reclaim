import AppKit

/// Asks for access to the Home folder once, then checks every place the tools read so macOS
/// prompts happen together, up front, instead of in the middle of a scan.
@MainActor @Observable
final class AccessCenter {
    static let shared = AccessCenter()

    enum Status: Equatable {
        case unknown, checking, granted, blocked, missing
    }

    struct Location: Identifiable, Equatable {
        let id: String
        let title: LocalizedStringResource
        let url: URL
        /// Which tools need it.
        let usedBy: LocalizedStringResource
        /// Only Full Disk Access opens it (no macOS prompt is offered).
        let needsFullDiskAccess: Bool
        var status: Status = .unknown
    }

    private(set) var locations: [Location]
    private(set) var isChecking = false
    private(set) var fullDiskAccess = FS.hasFullDiskAccess()
    private(set) var lastChecked: Date? = UserDefaults.standard.object(forKey: PrefKey.lastAccessCheck) as? Date

    /// True once the person granted the Home folder and the full check has run.
    var homeGranted: Bool { UserDefaults.standard.data(forKey: PrefKey.homeAccessBookmark) != nil && lastChecked != nil }

    var grantedCount: Int { locations.filter { $0.status == .granted }.count }
    var blockedCount: Int { locations.filter { $0.status == .blocked }.count }

    init() {
        let home = FS.home
        let temp = URL(fileURLWithPath: AIJunkContext.realPath(NSTemporaryDirectory()), isDirectory: true)
        func loc(_ id: String, _ title: LocalizedStringResource, _ url: URL, _ usedBy: LocalizedStringResource, fda: Bool = false) -> Location {
            Location(id: id, title: title, url: url, usedBy: usedBy, needsFullDiskAccess: fda)
        }
        locations = [
            loc("home", "Home folder", home, "Storage Map, Large & Old, every tool"),
            loc("desktop", "Desktop", FS.desktop, "Duplicates, Photo Clutter, Large & Old"),
            loc("documents", "Documents", FS.documents, "Duplicates, Large & Old"),
            loc("downloads", "Downloads", FS.downloads, "Downloads, Duplicates, Security Check"),
            loc("pictures", "Pictures", FS.pictures, "Photo Clutter, AI Junk"),
            loc("movies", "Movies", FS.movies, "Large & Old, Photo Clutter"),
            loc("music", "Music", FS.music, "Large & Old"),
            loc("library", "Library", home.appendingPathComponent("Library"), "Junk, Apps & Leftovers"),
            loc("caches", "App caches", FS.library("Caches"), "Junk"),
            loc("support", "Application Support", FS.library("Application Support"), "AI Junk, Apps & Leftovers"),
            loc("tmp", "System temp folder (/tmp)", URL(fileURLWithPath: "/private/tmp", isDirectory: true), "AI Junk"),
            loc("usertmp", "Your temp folder", temp, "AI Junk"),
            loc("claude", "Claude Code data (~/.claude)", home.appendingPathComponent(".claude"), "AI Junk"),
            loc("cache", "Developer caches (~/.cache)", home.appendingPathComponent(".cache"), "AI Junk, Junk"),
            loc("apps", "Applications", URL(fileURLWithPath: "/Applications", isDirectory: true), "Apps & Leftovers, Security Check"),
            loc("containers", "Other apps' data (Containers)", FS.library("Containers"), "Apps & Leftovers, Junk", fda: true),
            loc("mail", "Mail", FS.library("Mail"), "Junk (Mail downloads)", fda: true),
            loc("backups", "iPhone & iPad backups", FS.library("Application Support/MobileSync/Backup"), "Junk", fda: true),
            loc("trash", "Trash", home.appendingPathComponent(".Trash"), "Trash", fda: true),
        ]
    }

    /// Shows an Open panel at the Home folder; on approval, remembers the grant and checks everything.
    func grantHomeAccess() async {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = FS.home.deletingLastPathComponent()
        panel.message = String(localized: "Select your Home folder (\(FS.home.lastPathComponent)) and click Grant Access. Reclaim then checks every folder it scans; click Allow if macOS asks.")
        panel.prompt = String(localized: "Grant Access")
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let data = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: PrefKey.homeAccessBookmark)
        }
        if url.standardizedFileURL.path != FS.home.standardizedFileURL.path {
            FolderStore.shared.add(url)
        }
        await checkAll()
    }

    /// Reads each location in turn (one macOS prompt at a time) and records whether it's open to Reclaim.
    func checkAll() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        for i in locations.indices {
            locations[i].status = .checking
            let url = locations[i].url
            let status = await Task.detached(priority: .userInitiated) { AccessCenter.probe(url) }.value
            locations[i].status = status
        }
        fullDiskAccess = FS.hasFullDiskAccess()
        lastChecked = .now
        UserDefaults.standard.set(lastChecked, forKey: PrefKey.lastAccessCheck)
    }

    func refreshFullDiskAccess() { fullDiskAccess = FS.hasFullDiskAccess() }

    /// Grants Home (if needed) and checks, then runs `then`. Used by first scans so access is settled before scanning.
    func ensureAccess(then action: @escaping @MainActor () -> Void) {
        if homeGranted { action(); return }
        Task {
            await grantHomeAccess()
            action()
        }
    }

    nonisolated static func probe(_ url: URL) -> Status {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            // A protected folder can also look missing; tell the difference by its parent listing.
            let parent = url.deletingLastPathComponent()
            if let names = try? FileManager.default.contentsOfDirectory(atPath: parent.path), names.contains(url.lastPathComponent) {
                return .blocked
            }
            return .missing
        }
        if !isDir.boolValue { return FileManager.default.isReadableFile(atPath: url.path) ? .granted : .blocked }
        // Listing the folder is what triggers the macOS privacy prompt when one is needed.
        return (try? FileManager.default.contentsOfDirectory(atPath: url.path)) != nil ? .granted : .blocked
    }
}
