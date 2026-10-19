import Foundation

/// Where a tool is in its scan lifecycle.
enum ScanPhase: Equatable {
    case idle
    case scanning(String)
    case done(Date)
    case failed(String)

    var isScanning: Bool { if case .scanning = self { return true } else { return false } }
    var isDone: Bool { if case .done = self { return true } else { return false } }
    var lastScan: Date? { if case .done(let d) = self { return d } else { return nil } }
    var message: String? {
        switch self {
        case .scanning(let m), .failed(let m): return m
        default: return nil
        }
    }
}

/// A tool that scans and produces reclaimable results. Smart Scan and Guided Cleanup drive tools through this.
@MainActor
protocol ScanTool: AnyObject {
    var route: Route { get }
    var phase: ScanPhase { get }
    /// Bytes the last scan found that the person could review and reclaim.
    var reclaimableBytes: Int64 { get }
    /// Number of reviewable items the last scan found.
    var itemCount: Int { get }
    /// Runs a full scan and returns when it has finished (or was cancelled).
    func scan() async
    func cancelScan()
    /// The highest-impact items for Guided Cleanup, each with a clear reason.
    func suggestions() -> [CleanupSuggestion]
    /// Drops results that were moved to the Trash elsewhere (another tool, Guided Cleanup, the Storage Map).
    func forget(paths: Set<String>)
}

extension Set where Element == String {
    /// True if `path` itself, or any folder above it, is in the set.
    func containsPathOrAncestor(of path: String) -> Bool {
        if contains(path) { return true }
        var p = path
        while let slash = p.lastIndex(of: "/"), slash != p.startIndex {
            p = String(p[..<slash])
            if contains(p) { return true }
        }
        return false
    }
}

/// One proposed cleanup action, shown in Guided Cleanup.
struct CleanupSuggestion: Identifiable, Hashable {
    enum Confidence: Int, Comparable, CaseIterable {
        case lower, medium, high
        static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
        var label: String {
            switch self {
            case .high: return "High confidence"
            case .medium: return "Medium confidence"
            case .lower: return "Lower confidence"
            }
        }
    }

    /// Stable id: "<tool>:<path>".
    let id: String
    let tool: Route
    /// e.g. "Older installer: Zoom.pkg"
    let title: String
    /// Why it was suggested, in one or two plain sentences.
    let reason: String
    /// Short facts backing the reason, e.g. ["Last changed 8 months ago", "1.2 GB"].
    let evidence: [String]
    let url: URL
    let bytes: Int64
    /// Modification date at audit time; the item is skipped if it changes before the plan runs.
    let modified: Date?
    let confidence: Confidence

    init(tool: Route, title: String, reason: String, evidence: [String] = [], url: URL, bytes: Int64, modified: Date?, confidence: Confidence) {
        self.id = "\(tool.rawValue):\(url.path)"
        self.tool = tool
        self.title = title
        self.reason = reason
        self.evidence = evidence
        self.url = url
        self.bytes = bytes
        self.modified = modified
        self.confidence = confidence
    }
}

/// Throttled progress messages from a background scan to the main actor.
final class ProgressReporter: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast
    private let interval: TimeInterval
    private let handler: @MainActor (String) -> Void

    init(interval: TimeInterval = 0.15, _ handler: @escaping @MainActor (String) -> Void) {
        self.interval = interval
        self.handler = handler
    }

    func report(_ message: @autoclosure () -> String, force: Bool = false) {
        let now = Date()
        lock.lock()
        let due = force || now.timeIntervalSince(last) >= interval
        if due { last = now }
        lock.unlock()
        guard due else { return }
        let text = message()
        let handler = self.handler
        Task { @MainActor in handler(text) }
    }
}

/// Which folders a tool scans.
enum ScanScope: Hashable {
    /// The tool's own default folders.
    case defaults
    case home
    case folder(URL)

    func roots(defaults: [URL]) -> [URL] {
        switch self {
        case .defaults: return defaults
        case .home: return [FS.home]
        case .folder(let url): return [url]
        }
    }

    func label(defaultsLabel: String) -> String {
        switch self {
        case .defaults: return defaultsLabel
        case .home: return "Home folder"
        case .folder(let url): return FS.abbreviate(url.path)
        }
    }
}
