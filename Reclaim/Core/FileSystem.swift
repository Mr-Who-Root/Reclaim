import AppKit
import UniformTypeIdentifiers

/// One file or folder found by a scan.
struct FileEntry: Identifiable, Hashable, Sendable {
    let url: URL
    /// Allocated size on disk. For folders, the recursive total.
    let size: Int64
    let modified: Date?
    let created: Date?
    let isDirectory: Bool

    var id: String { url.path }
    var path: String { url.path }
    var name: String { url.lastPathComponent }
    var displayPath: String { FS.abbreviate(url.path) }
    var parentDisplayPath: String { FS.abbreviate(url.deletingLastPathComponent().path) }
    var ext: String { url.pathExtension.lowercased() }
}

/// File-system helpers shared by every tool.
enum FS {
    static let fm = FileManager.default
    static var home: URL { SharedPaths.home }

    static func library(_ sub: String) -> URL { home.appendingPathComponent("Library", isDirectory: true).appendingPathComponent(sub) }
    static var downloads: URL { home.appendingPathComponent("Downloads", isDirectory: true) }
    static var desktop: URL { home.appendingPathComponent("Desktop", isDirectory: true) }
    static var documents: URL { home.appendingPathComponent("Documents", isDirectory: true) }
    static var movies: URL { home.appendingPathComponent("Movies", isDirectory: true) }
    static var pictures: URL { home.appendingPathComponent("Pictures", isDirectory: true) }
    static var music: URL { home.appendingPathComponent("Music", isDirectory: true) }

    static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isPackageKey, .isHiddenKey,
        .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey,
        .contentModificationDateKey, .creationDateKey,
    ]
    static let resourceKeySet = Set(resourceKeys)

    /// Replaces the home prefix with `~`.
    static func abbreviate(_ path: String) -> String {
        let h = home.path
        if path == h { return "~" }
        if path.hasPrefix(h + "/") { return "~" + path.dropFirst(h.count) }
        return path
    }

    static func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }

    static func isDirectory(_ url: URL) -> Bool {
        var dir: ObjCBool = false
        return fm.fileExists(atPath: url.path, isDirectory: &dir) && dir.boolValue
    }

    /// Allocated bytes for a single file's resource values.
    static func allocated(_ v: URLResourceValues) -> Int64 {
        Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? v.fileSize ?? 0)
    }

    /// Size on disk of a file, or the recursive total of a folder or package.
    /// Checks `Task.isCancelled` so long walks can be stopped.
    static func allocatedSize(of url: URL) -> Int64 {
        guard let v = try? url.resourceValues(forKeys: resourceKeySet) else { return 0 }
        if v.isSymbolicLink == true { return 0 }
        if v.isDirectory != true { return allocated(v) }
        var total: Int64 = 0
        guard let e = fm.enumerator(at: url, includingPropertiesForKeys: resourceKeys, options: [], errorHandler: { _, _ in true }) else { return 0 }
        var n = 0
        for case let child as URL in e {
            n += 1
            if n & 1023 == 0, Task.isCancelled { break }
            guard let cv = try? child.resourceValues(forKeys: resourceKeySet), cv.isRegularFile == true else { continue }
            total += allocated(cv)
        }
        return total
    }

    /// Builds an entry. Folders get their recursive size when `measureFolders` is true.
    static func entry(for url: URL, measureFolders: Bool = true) -> FileEntry? {
        guard let v = try? url.resourceValues(forKeys: resourceKeySet) else { return nil }
        let isDir = v.isDirectory == true
        let size = isDir ? (measureFolders ? allocatedSize(of: url) : 0) : allocated(v)
        return FileEntry(url: url, size: size, modified: v.contentModificationDate, created: v.creationDate, isDirectory: isDir)
    }

    /// Immediate children of a folder (empty if unreadable).
    static func children(of url: URL, includeHidden: Bool = false) -> [URL] {
        let opts: FileManager.DirectoryEnumerationOptions = includeHidden ? [] : [.skipsHiddenFiles]
        return (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: resourceKeys, options: opts)) ?? []
    }

    /// Whether a folder can actually be listed (macOS privacy can silently block it).
    static func canList(_ url: URL) -> Bool {
        (try? fm.contentsOfDirectory(atPath: url.path)) != nil
    }

    /// Walks every regular file under `roots`. Return `false` from `body` to stop.
    /// Hidden files are skipped unless `includeHidden`; package contents (.app, .photoslibrary…) are skipped unless `intoPackages`.
    static func walkFiles(_ roots: [URL], includeHidden: Bool = false, intoPackages: Bool = false,
                          body: (URL, URLResourceValues) -> Bool) {
        var opts: FileManager.DirectoryEnumerationOptions = []
        if !includeHidden { opts.insert(.skipsHiddenFiles) }
        if !intoPackages { opts.insert(.skipsPackageDescendants) }
        var seen = Set<String>()
        for root in roots where seen.insert(root.standardizedFileURL.path).inserted {
            guard let e = fm.enumerator(at: root, includingPropertiesForKeys: resourceKeys, options: opts, errorHandler: { _, _ in true }) else { continue }
            var n = 0
            for case let url as URL in e {
                n += 1
                if n & 511 == 0, Task.isCancelled { return }
                guard let v = try? url.resourceValues(forKeys: resourceKeySet) else { continue }
                if v.isRegularFile != true { continue }
                if !body(url, v) { return }
            }
        }
    }

    /// Whether this process has Full Disk Access (needed for Mail, Safari, iOS backups and other apps' containers).
    static func hasFullDiskAccess() -> Bool {
        let probe = library("Application Support/com.apple.TCC/TCC.db").path
        let fd = Darwin.open(probe, O_RDONLY)
        if fd >= 0 { Darwin.close(fd); return true }
        return FS.canList(library("Safari"))
    }

    static func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    static func reveal(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    static func openTrash() {
        NSWorkspace.shared.open(home.appendingPathComponent(".Trash", isDirectory: true))
    }

    /// A coarse kind used for filters and colours.
    enum Kind: String, CaseIterable, Identifiable {
        case video = "Video", audio = "Audio", image = "Images", archive = "Archives", diskImage = "Disk Images",
             document = "Documents", app = "Apps", code = "Code", other = "Other"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .video: return "film"
            case .audio: return "waveform"
            case .image: return "photo"
            case .archive: return "doc.zipper"
            case .diskImage: return "opticaldiscdrive"
            case .document: return "doc.text"
            case .app: return "app"
            case .code: return "chevron.left.forwardslash.chevron.right"
            case .other: return "doc"
            }
        }
    }

    static let archiveExtensions: Set<String> = ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "tbz", "txz", "zst", "lz", "lzma", "cab", "sit", "sitx"]
    static let installerExtensions: Set<String> = ["dmg", "pkg", "mpkg", "iso", "xip", "img", "msi", "exe", "apk", "ipa"]

    static func kind(of url: URL) -> Kind {
        let ext = url.pathExtension.lowercased()
        if ext == "app" { return .app }
        if installerExtensions.contains(ext) { return .diskImage }
        if archiveExtensions.contains(ext) { return .archive }
        guard let type = UTType(filenameExtension: ext) else { return .other }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .archive) { return .archive }
        if type.conforms(to: .diskImage) { return .diskImage }
        if type.conforms(to: .sourceCode) || type.conforms(to: .script) { return .code }
        if type.conforms(to: .pdf) || type.conforms(to: .presentation) || type.conforms(to: .spreadsheet)
            || type.conforms(to: .text) || type.conforms(to: .compositeContent) { return .document }
        return .other
    }
}

/// Formatting helpers.
enum Fmt {
    static func bytes(_ n: Int64) -> String { ByteText.string(n) }

    static func count(_ n: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(n.formatted()) \(n == 1 ? singular : (plural ?? singular + "s"))"
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    static func relative(_ date: Date?) -> String {
        guard let date else { return "—" }
        if abs(date.timeIntervalSinceNow) < 60 { return "just now" }
        return relativeFormatter.localizedString(for: date, relativeTo: .now)
    }

    static func date(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    static func dateTime(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    /// "8 months", "2 years" — how long since a date.
    static func age(_ date: Date?) -> String {
        guard let date else { return "unknown age" }
        let days = Int(-date.timeIntervalSinceNow / 86_400)
        if days < 1 { return "today" }
        if days < 31 { return Fmt.count(days, "day") }
        if days < 365 { return Fmt.count(days / 30, "month") }
        return Fmt.count(days / 365, "year")
    }

    static func percent(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0)))
    }
}

extension Date {
    /// Whole days since this date.
    var daysAgo: Int { Int(-timeIntervalSinceNow / 86_400) }
}

/// Cached Finder icons.
@MainActor
enum FileIcons {
    private static let cache = NSCache<NSString, NSImage>()
    static func icon(for url: URL) -> NSImage {
        let key = url.path as NSString
        if let img = cache.object(forKey: key) { return img }
        let img = NSWorkspace.shared.icon(forFile: url.path)
        cache.setObject(img, forKey: key)
        return img
    }
}
