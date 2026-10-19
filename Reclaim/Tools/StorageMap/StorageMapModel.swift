import SwiftUI
import AppKit

/// One folder, file, or merged group of small items in the storage map.
/// A reference type so trashing can update sizes up the tree in place.
final class MapNode: Identifiable {
    let id: String
    let url: URL
    let name: String
    var size: Int64
    /// Regular files inside (1 for a file, the merged count for an aggregate).
    var fileCount: Int
    let isDirectory: Bool
    let isPackage: Bool
    let modified: Date?
    var children: [MapNode] = []
    weak var parent: MapNode?
    /// The folder couldn't be listed, so its size is unknown (not zero).
    var unreadable = false
    /// Unreadable folders anywhere below this node.
    var unknownCount = 0
    /// > 0 for the "N smaller items" node that stands in for pruned children.
    var aggregateCount = 0

    var isAggregate: Bool { aggregateCount > 0 }
    /// Can be opened, collected or trashed (real items only).
    var isActionable: Bool { !isAggregate && parent != nil }

    init(url: URL, size: Int64 = 0, fileCount: Int = 0, isDirectory: Bool, isPackage: Bool = false, modified: Date? = nil) {
        self.id = url.path
        self.url = url
        self.name = url.path == "/" ? "Macintosh HD" : url.lastPathComponent
        self.size = size
        self.fileCount = fileCount
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        self.modified = modified
    }

    /// The merged stand-in for children that were pruned to keep memory bounded.
    init(aggregateIn folder: URL, count: Int, size: Int64, files: Int) {
        self.id = folder.path + "#smaller"
        self.url = folder
        self.name = "\(count.formatted()) smaller items"
        self.size = size
        self.fileCount = files
        self.isDirectory = false
        self.isPackage = false
        self.modified = nil
        self.aggregateCount = count
    }

    private var cachedKind: FS.Kind?
    /// File kind for colouring (computed lazily; only displayed nodes need it).
    var kind: FS.Kind {
        if let cachedKind { return cachedKind }
        let k = FS.kind(of: url)
        cachedKind = k
        return k
    }

    var ancestors: [MapNode] {
        var list: [MapNode] = []
        var n = parent
        while let node = n { list.append(node); n = node.parent }
        return list
    }

    func isDescendant(of other: MapNode) -> Bool {
        var n = parent
        while let node = n {
            if node === other { return true }
            n = node.parent
        }
        return false
    }
}

/// Builds the map tree off the main thread. Thread-safe counters; cancel with `cancel()`.
final class StorageMapScanner: @unchecked Sendable {
    static let keepFiles = 60
    static let maxChildren = 150

    private let lock = NSLock()
    private var cancelledFlag = false
    private var files = 0
    private var bytes: Int64 = 0
    private var unreadablePaths: [String] = []
    private let reporter: ProgressReporter
    private let skip: Set<String>

    init(reporter: ProgressReporter, skip: Set<String>) {
        self.reporter = reporter
        self.skip = skip
    }

    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelledFlag }
    func cancel() { lock.lock(); cancelledFlag = true; lock.unlock() }
    var unreadable: [String] { lock.lock(); defer { lock.unlock() }; return unreadablePaths }
    var totals: (files: Int, bytes: Int64) { lock.lock(); defer { lock.unlock() }; return (files, bytes) }

    func scan(_ root: URL) -> MapNode {
        let node = build(root, isPackage: false, depth: 0)
        let t = totals
        reporter.report("Mapped \(t.files.formatted()) files · \(Fmt.bytes(t.bytes))", force: true)
        return node
    }

    private func record(files n: Int, bytes b: Int64, at url: URL) {
        lock.lock()
        files += n
        bytes += b
        let t = (files, bytes)
        lock.unlock()
        reporter.report("Mapped \(t.0.formatted()) files · \(Fmt.bytes(t.1)) — \(FS.abbreviate(url.path))")
    }

    private func recordUnreadable(_ url: URL) {
        lock.lock()
        unreadablePaths.append(url.path)
        lock.unlock()
    }

    private func build(_ url: URL, isPackage: Bool, depth: Int) -> MapNode {
        let node = MapNode(url: url, isDirectory: true, isPackage: isPackage)
        if isCancelled { return node }

        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: FS.resourceKeys, options: [])
        } catch {
            node.unreadable = true
            recordUnreadable(url)
            return node
        }

        var dirs: [(url: URL, package: Bool)] = []
        var fileList: [(url: URL, size: Int64, modified: Date?)] = []
        for child in contents {
            if skip.contains(child.path) { continue }
            guard let v = try? child.resourceValues(forKeys: FS.resourceKeySet) else { continue }
            if v.isSymbolicLink == true { continue }
            if v.isDirectory == true {
                dirs.append((child, v.isPackage == true))
            } else if v.isRegularFile == true {
                fileList.append((child, FS.allocated(v), v.contentModificationDate))
            }
        }
        record(files: fileList.count, bytes: fileList.reduce(0) { $0 + $1.size }, at: url)

        // Subfolders: in parallel near the top of the tree, sequentially below.
        var dirNodes = [MapNode?](repeating: nil, count: dirs.count)
        if depth < 2, dirs.count > 1 {
            dirNodes.withUnsafeMutableBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                DispatchQueue.concurrentPerform(iterations: dirs.count) { i in
                    base[i] = self.build(dirs[i].url, isPackage: dirs[i].package, depth: depth + 1)
                }
            }
        } else {
            for (i, d) in dirs.enumerated() {
                if isCancelled { break }
                dirNodes[i] = build(d.url, isPackage: d.package, depth: depth + 1)
            }
        }

        var children: [MapNode] = []
        var unknown: [MapNode] = []
        for case let d? in dirNodes {
            if d.unreadable { unknown.append(d) } else { children.append(d) }
        }

        // Keep only the biggest files as nodes; merge the rest.
        fileList.sort { $0.size > $1.size }
        let keptFiles = fileList.prefix(Self.keepFiles)
        children += keptFiles.map { MapNode(url: $0.url, size: $0.size, fileCount: 1, isDirectory: false, modified: $0.modified) }
        var mergedCount = fileList.count - keptFiles.count
        var mergedBytes = fileList.dropFirst(Self.keepFiles).reduce(Int64(0)) { $0 + $1.size }
        var mergedFiles = mergedCount

        children.sort { $0.size > $1.size }
        if children.count > Self.maxChildren {
            let extra = children[Self.maxChildren...]
            mergedCount += extra.count
            mergedBytes += extra.reduce(Int64(0)) { $0 + $1.size }
            mergedFiles += extra.reduce(0) { $0 + $1.fileCount }
            // Keep track of unknown folders hidden inside pruned subtrees.
            node.unknownCount += extra.reduce(0) { $0 + $1.unknownCount }
            children = Array(children.prefix(Self.maxChildren))
        }
        if mergedCount > 0 {
            children.append(MapNode(aggregateIn: url, count: mergedCount, size: mergedBytes, files: mergedFiles))
            children.sort { $0.size > $1.size }
        }
        children += unknown

        node.size = children.reduce(0) { $0 + $1.size }
        node.fileCount = children.reduce(0) { $0 + $1.fileCount }
        node.unknownCount += children.reduce(0) { $0 + $1.unknownCount + ($1.unreadable ? 1 : 0) }
        for c in children { c.parent = node }
        node.children = children
        return node
    }
}

@MainActor @Observable
final class StorageMapModel {
    enum Target: Hashable {
        case home, startup, folder(URL)

        var url: URL {
            switch self {
            case .home: return FS.home
            case .startup: return URL(fileURLWithPath: "/", isDirectory: true)
            case .folder(let u): return u
            }
        }

        var label: String {
            switch self {
            case .home: return "Home folder"
            case .startup: return "Macintosh HD"
            case .folder(let u): return FS.abbreviate(u.path)
            }
        }
    }

    var target: Target = .home
    var phase: ScanPhase = .idle
    private(set) var root: MapNode?
    private(set) var current: MapNode?
    var hoveredID: String?
    private(set) var collector: [MapNode] = []
    private(set) var unreadable: [String] = []
    var isTrashing = false
    /// Bumped after in-place tree changes so views refresh.
    private(set) var revision = 0

    private var scanner: StorageMapScanner?
    private var lastDone: Date?

    /// Firmlinked and virtual paths that would double-count or never finish when mapping "/".
    private static let startupSkips: Set<String> = ["/System/Volumes", "/Volumes", "/dev", "/net", "/home", "/cores/.vol", "/.vol"]

    func scan() async {
        scanner?.cancel()
        let url = target.url
        let skip = target == .startup ? Self.startupSkips : []
        phase = .scanning("Starting…")
        let reporter = ProgressReporter { [weak self] message in
            guard let self, self.phase.isScanning else { return }
            self.phase = .scanning(message)
        }
        let scanner = StorageMapScanner(reporter: reporter, skip: skip)
        self.scanner = scanner
        let node = await Task.detached(priority: .userInitiated) { () -> MapNode in
            scanner.scan(url)
        }.value
        guard self.scanner === scanner else { return }
        if scanner.isCancelled {
            phase = lastDone.map { .done($0) } ?? .idle
            return
        }
        root = node
        current = node
        collector = []
        hoveredID = nil
        unreadable = scanner.unreadable.sorted()
        lastDone = .now
        phase = .done(.now)
        revision += 1
    }

    func cancelScan() {
        scanner?.cancel()
    }

    // MARK: Navigation

    var breadcrumb: [MapNode] {
        guard let current else { return [] }
        return (current.ancestors.reversed()) + [current]
    }

    var canGoUp: Bool { current?.parent != nil }

    func drill(into node: MapNode) {
        guard node.isDirectory, !node.unreadable, !node.children.isEmpty else { return }
        current = node
        hoveredID = nil
    }

    func goUp() {
        guard let parent = current?.parent else { return }
        current = parent
        hoveredID = nil
    }

    func go(to node: MapNode) {
        current = node
        hoveredID = nil
    }

    // MARK: Collector

    func isCollected(_ node: MapNode) -> Bool {
        collector.contains { $0 === node || node.isDescendant(of: $0) }
    }

    func addToCollector(_ node: MapNode) {
        guard node.isActionable, !isCollected(node) else { return }
        // A folder covers anything already collected inside it.
        collector.removeAll { $0.isDescendant(of: node) }
        collector.append(node)
    }

    func removeFromCollector(_ node: MapNode) {
        collector.removeAll { $0 === node }
    }

    func clearCollector() { collector.removeAll() }

    var collectorBytes: Int64 { collector.reduce(0) { $0 + $1.size } }

    // MARK: Trash

    func trashCollector() async {
        await trash(collector)
    }

    func trash(_ nodes: [MapNode]) async {
        let targets = nodes.filter(\.isActionable)
        guard !targets.isEmpty, !isTrashing else { return }
        isTrashing = true
        defer { isTrashing = false }
        let moved = await AppModel.shared.trash(targets.map { (url: $0.url, bytes: $0.size) }, from: .map)
        for node in targets where moved.contains(node.url.path) {
            remove(node)
        }
        collector.removeAll { moved.contains($0.url.path) || $0.parent == nil }
        revision += 1
    }

    /// Detaches a node and subtracts its size and file count from every ancestor.
    private func remove(_ node: MapNode) {
        guard let parent = node.parent else { return }
        if let current, current === node || current.isDescendant(of: node) {
            self.current = parent
        }
        parent.children.removeAll { $0 === node }
        let unknown = node.unknownCount + (node.unreadable ? 1 : 0)
        var n: MapNode? = parent
        while let a = n {
            a.size -= node.size
            a.fileCount -= node.fileCount
            a.unknownCount -= unknown
            n = a.parent
        }
        node.parent = nil
        if hoveredID == node.id { hoveredID = nil }
    }
}
