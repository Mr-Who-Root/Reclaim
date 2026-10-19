import AppKit

/// One item Reclaim moved to the Trash.
struct TrashRecord: Codable, Identifiable, Hashable {
    var id = UUID()
    var originalPath: String
    /// Where macOS put it inside the Trash (needed to restore).
    var trashedPath: String?
    var bytes: Int64
    var date: Date
    var tool: String
    var restored = false

    var name: String { (originalPath as NSString).lastPathComponent }
    var originalURL: URL { URL(fileURLWithPath: originalPath) }
    var trashedURL: URL? { trashedPath.map { URL(fileURLWithPath: $0) } }
    var route: Route? { Route(rawValue: tool) }

    /// Still sitting in the Trash (not restored, not emptied).
    var isInTrash: Bool {
        guard !restored, let trashedPath else { return false }
        return FileManager.default.fileExists(atPath: trashedPath)
    }
}

struct TrashFailure: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let reason: String
}

struct TrashBatch {
    var moved: [TrashRecord] = []
    var failed: [TrashFailure] = []
    var bytes: Int64 { moved.reduce(0) { $0 + $1.bytes } }
    var movedPaths: Set<String> { Set(moved.map(\.originalPath)) }
}

/// Moves files to the Trash and remembers them so they can be reviewed and restored.
@MainActor @Observable
final class TrashLog {
    static let shared = TrashLog()

    private(set) var records: [TrashRecord] = []

    private var fileURL: URL { SharedPaths.support.appendingPathComponent("trash-history.json") }

    init() { load() }

    /// Total bytes Reclaim has moved to the Trash (excluding restored items).
    var totalReclaimed: Int64 { records.filter { !$0.restored }.reduce(0) { $0 + $1.bytes } }

    /// Moves items to the Trash off the main thread and records what reached it.
    func moveToTrash(_ items: [(url: URL, bytes: Int64)], tool: Route) async -> TrashBatch {
        let toolName = tool.rawValue
        let batch = await Task.detached(priority: .userInitiated) {
            TrashService.perform(items, tool: toolName)
        }.value
        if !batch.moved.isEmpty {
            records.insert(contentsOf: batch.moved, at: 0)
            save()
        }
        return batch
    }

    /// Puts trashed items back where they came from. Returns how many were restored and why others weren't.
    func restore(_ ids: [UUID]) async -> (restored: Int, failures: [String]) {
        var restored = 0
        var failures: [String] = []
        for id in ids {
            guard let i = records.firstIndex(where: { $0.id == id }) else { continue }
            let record = records[i]
            do {
                try TrashService.restore(record)
                records[i].restored = true
                restored += 1
            } catch {
                failures.append("\(record.name): \(error.localizedDescription)")
            }
        }
        save()
        return (restored, failures)
    }

    func clearHistory() {
        records.removeAll()
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        records = (try? decoder.decode([TrashRecord].self, from: data)) ?? []
    }

    private func save() {
        try? FileManager.default.createDirectory(at: SharedPaths.support, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(Array(records.prefix(5000))) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

enum TrashError: LocalizedError {
    case notInTrash, destinationTaken, message(String)
    var errorDescription: String? {
        switch self {
        case .notInTrash: return "It is no longer in the Trash."
        case .destinationTaken: return "The original location is no longer free, so it was not restored."
        case .message(let m): return m
        }
    }
}

enum TrashService {
    /// Synchronous; call from a background task.
    static func perform(_ items: [(url: URL, bytes: Int64)], tool: String) -> TrashBatch {
        var batch = TrashBatch()
        let fm = FileManager.default
        for item in items {
            guard fm.fileExists(atPath: item.url.path) || (try? item.url.checkResourceIsReachable()) == true else {
                batch.failed.append(TrashFailure(url: item.url, reason: "It is no longer where it was during the scan."))
                continue
            }
            do {
                var resulting: NSURL?
                try fm.trashItem(at: item.url, resultingItemURL: &resulting)
                batch.moved.append(TrashRecord(originalPath: item.url.path, trashedPath: (resulting as URL?)?.path,
                                               bytes: item.bytes, date: .now, tool: tool))
            } catch {
                batch.failed.append(TrashFailure(url: item.url, reason: friendly(error)))
            }
        }
        return batch
    }

    static func restore(_ record: TrashRecord) throws {
        guard let trashed = record.trashedURL, FileManager.default.fileExists(atPath: trashed.path) else { throw TrashError.notInTrash }
        let original = record.originalURL
        if FileManager.default.fileExists(atPath: original.path) { throw TrashError.destinationTaken }
        try FileManager.default.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: trashed, to: original)
    }

    static func friendly(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain {
            switch ns.code {
            case NSFileWriteNoPermissionError, NSFileReadNoPermissionError:
                return "macOS didn't allow it to be moved. It may be protected or owned by another user."
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError:
                return "It is no longer where it was during the scan."
            case NSFileWriteVolumeReadOnlyError:
                return "It's on a read-only volume."
            default: break
            }
        }
        return ns.localizedDescription
    }

    /// Asks Finder to empty the Trash (Finder shows its own confirmation if needed).
    static func emptyTrashWithFinder() -> String? {
        runFinderScript("tell application \"Finder\" to empty trash")
    }

    /// Asks Finder to delete an item; Finder prompts for an administrator password when required.
    static func trashWithFinder(_ url: URL) -> String? {
        let escaped = url.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return runFinderScript("tell application \"Finder\" to delete (POSIX file \"\(escaped)\" as alias)")
    }

    /// Returns an error message, or nil on success.
    private static func runFinderScript(_ source: String) -> String? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return "Couldn't build the Finder request." }
        script.executeAndReturnError(&error)
        if let error { return (error[NSAppleScript.errorMessage] as? String) ?? "Finder declined the request." }
        return nil
    }

    /// Size of the user's Trash, if readable (needs Full Disk Access on recent macOS).
    static func currentTrashSize() -> Int64? {
        let trash = FS.home.appendingPathComponent(".Trash", isDirectory: true)
        guard FS.canList(trash) else { return nil }
        return FS.allocatedSize(of: trash)
    }
}
