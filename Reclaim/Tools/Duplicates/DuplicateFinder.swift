import Foundation
import CryptoKit
import Darwin

/// A set of files whose contents are byte-for-byte identical.
struct DuplicateGroup: Identifiable, Hashable {
    /// The content hash.
    let id: String
    /// Logical size of each copy.
    let fileSize: Int64
    var files: [FileEntry]
    var keeperPath: String

    var keeper: FileEntry? { files.first { $0.path == keeperPath } }
    var copies: [FileEntry] { files.filter { $0.path != keeperPath } }
    /// Bytes freed by removing every copy except the keeper.
    var wasted: Int64 { copies.reduce(0) { $0 + $1.size } }
    var name: String { keeper?.name ?? files.first?.name ?? "" }
}

/// Which copy of each group stays.
enum DupKeepRule: String, CaseIterable, Identifiable {
    case oldest, newest, shortestPath
    var id: String { rawValue }
    var label: String {
        switch self {
        case .oldest: return "Keep the oldest copy"
        case .newest: return "Keep the newest copy"
        case .shortestPath: return "Keep the copy with the shortest path"
        }
    }
    var shortLabel: String {
        switch self {
        case .oldest: return "Oldest"
        case .newest: return "Newest"
        case .shortestPath: return "Shortest path"
        }
    }

    func pickKeeper(_ files: [FileEntry]) -> FileEntry? {
        func born(_ f: FileEntry) -> Date { f.created ?? f.modified ?? .distantFuture }
        func changed(_ f: FileEntry) -> Date { f.modified ?? f.created ?? .distantPast }
        switch self {
        case .oldest:
            return files.min { (born($0), $0.path.count) < (born($1), $1.path.count) }
        case .newest:
            return files.max { (changed($0), -$0.path.count) < (changed($1), -$1.path.count) }
        case .shortestPath:
            return files.min { ($0.path.count, born($0)) < ($1.path.count, born($1)) }
        }
    }
}

/// Smallest file the duplicate scan considers.
enum DupMinSize: Int64, CaseIterable, Identifiable {
    case kb1 = 1_024
    case kb100 = 102_400
    case mb1 = 1_048_576
    case mb10 = 10_485_760
    case mb100 = 104_857_600
    var id: Int64 { rawValue }
    var label: String {
        switch self {
        case .kb1: return "1 KB"
        case .kb100: return "100 KB"
        case .mb1: return "1 MB"
        case .mb10: return "10 MB"
        case .mb100: return "100 MB"
        }
    }
}

/// Finds byte-for-byte duplicates: group by size, then a partial hash (first + last 64 KB),
/// then a full streaming SHA-256 only where partial hashes collide. Synchronous and cancellable;
/// run it from a background task.
enum DuplicateFinder {
    struct Stats {
        var filesSeen = 0
        var filesCompared = 0
        var bytesHashed: Int64 = 0
    }

    struct Result {
        var groups: [(hash: String, size: Int64, files: [FileEntry])]
        var stats: Stats
    }

    private struct Candidate {
        let url: URL
        let size: Int64
        let allocated: Int64
        let modified: Date?
        let created: Date?
        var entry: FileEntry {
            FileEntry(url: url, size: allocated > 0 ? allocated : size, modified: modified, created: created, isDirectory: false)
        }
    }

    /// Returns nil when cancelled. With `skipProjects`, code projects are left out: copies inside repositories are there on purpose.
    static func run(roots: [URL], minSize: Int64, skipProjects: Bool = false, progress: ProgressReporter) -> Result? {
        var stats = Stats()

        // 1. Walk and bucket by logical size.
        var bySize: [Int64: [Candidate]] = [:]
        var seenPaths = Set<String>()
        progress.report("Looking through files…", force: true)
        FS.walkFiles(roots, skipFolder: skipProjects ? FS.isCodeProject : nil) { url, v in
            let size = Int64(v.fileSize ?? 0)
            guard size > 0, size >= minSize, v.isSymbolicLink != true else { return true }
            guard seenPaths.insert(url.path).inserted else { return true }
            stats.filesSeen += 1
            bySize[size, default: []].append(Candidate(url: url, size: size, allocated: FS.allocated(v),
                                                       modified: v.contentModificationDate, created: v.creationDate))
            progress.report("Looking through files… \(stats.filesSeen.formatted()) found")
            return true
        }
        if Task.isCancelled { return nil }

        // Only sizes shared by 2+ files can hold duplicates. Drop hard links to the same inode.
        var sizeGroups: [[Candidate]] = []
        for (_, list) in bySize where list.count > 1 {
            var inodes = Set<String>()
            let unique = list.filter { c in
                var st = stat()
                guard lstat(c.url.path, &st) == 0 else { return false }
                return inodes.insert("\(st.st_dev):\(st.st_ino)").inserted
            }
            if unique.count > 1 { sizeGroups.append(unique) }
        }
        let toCompare = sizeGroups.reduce(0) { $0 + $1.count }

        // 2. Partial hash.
        var partialGroups: [(hash: String, files: [Candidate])] = []
        for group in sizeGroups {
            var byPartial: [String: [Candidate]] = [:]
            for c in group {
                if Task.isCancelled { return nil }
                stats.filesCompared += 1
                progress.report("Comparing files \(stats.filesCompared.formatted()) of \(toCompare.formatted())")
                guard let h = partialHash(c.url, size: c.size) else { continue }
                byPartial[h, default: []].append(c)
            }
            for (h, list) in byPartial where list.count > 1 { partialGroups.append((h, list)) }
        }

        // 3. Full hash where the partial hash didn't already cover the whole file.
        let totalToHash = partialGroups.reduce(Int64(0)) { sum, g in
            g.files[0].size > Int64(partialChunk * 2) ? sum + g.files[0].size * Int64(g.files.count) : sum
        }
        var result: [(hash: String, size: Int64, files: [FileEntry])] = []
        for (partial, group) in partialGroups {
            let size = group[0].size
            if size <= Int64(partialChunk * 2) {
                // The partial hash read every byte, so it is already exact.
                result.append((partial, size, group.map(\.entry)))
                continue
            }
            var byFull: [String: [Candidate]] = [:]
            for c in group {
                if Task.isCancelled { return nil }
                let h = fullHash(c.url) { n in
                    stats.bytesHashed += Int64(n)
                    progress.report("Checking contents · \(Fmt.bytes(stats.bytesHashed)) of \(Fmt.bytes(totalToHash))")
                }
                if Task.isCancelled { return nil }
                guard let h else { continue }
                byFull[h, default: []].append(c)
            }
            for (h, list) in byFull where list.count > 1 {
                result.append((h, size, list.map(\.entry)))
            }
        }
        return Result(groups: result, stats: stats)
    }

    static let partialChunk = 64 * 1024
    static let fullChunk = 1024 * 1024

    /// SHA-256 of the size plus the first and last 64 KB. For files up to 128 KB this covers every byte.
    static func partialHash(_ url: URL, size: Int64) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        withUnsafeBytes(of: size.littleEndian) { hasher.update(bufferPointer: $0) }
        do {
            try autoreleasepool {
                if let head = try handle.read(upToCount: partialChunk) { hasher.update(data: head) }
                if size > Int64(partialChunk * 2) {
                    try handle.seek(toOffset: UInt64(size) - UInt64(partialChunk))
                    if let tail = try handle.read(upToCount: partialChunk) { hasher.update(data: tail) }
                } else if size > Int64(partialChunk) {
                    if let rest = try handle.readToEnd() { hasher.update(data: rest) }
                }
            }
        } catch {
            return nil
        }
        return hex(hasher.finalize())
    }

    /// Streaming SHA-256 of the whole file in 1 MB chunks. Returns nil if unreadable or cancelled.
    static func fullHash(_ url: URL, onBytes: (Int) -> Void = { _ in }) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            if Task.isCancelled { return nil }
            let chunk: Data?
            do {
                chunk = try autoreleasepool { try handle.read(upToCount: fullChunk) }
            } catch {
                return nil
            }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
            onBytes(chunk.count)
        }
        return hex(hasher.finalize())
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
