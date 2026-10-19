import Foundation

/// What's in the Trash right now. Measured by Smart Scan and the Trash page; never empties anything.
@MainActor @Observable
final class TrashStatus {
    static let shared = TrashStatus()

    var phase: ScanPhase = .idle
    /// Everything in the Trash, from any app. Nil when macOS doesn't let Reclaim read it (needs Full Disk Access).
    private(set) var totalBytes: Int64?
    private(set) var itemCount: Int?
    /// Items Reclaim moved that are still in the Trash (restorable).
    private(set) var reclaimIDsInTrash: Set<UUID> = []
    /// False when macOS hides the Trash from Reclaim (no Full Disk Access). Then nothing can be confirmed as emptied.
    private(set) var readable = true

    var recoverableBytes: Int64 {
        TrashLog.shared.records.filter { reclaimIDsInTrash.contains($0.id) }.reduce(0) { $0 + $1.bytes }
    }

    /// Bytes waiting to be freed by emptying the Trash (what Reclaim can see).
    var waitingBytes: Int64 { totalBytes ?? recoverableBytes }

    func scan() async {
        phase = .scanning(String(localized: "Measuring the Trash…"))
        let records = TrashLog.shared.records
        let result = await Task.detached(priority: .utility) { () -> (Set<UUID>, Int64?, Int?) in
            let trash = FS.home.appendingPathComponent(".Trash", isDirectory: true)
            // Without access every lookup inside the Trash fails, so treat unrestored items as possibly still there.
            guard FS.canList(trash) else { return (Set(records.filter { !$0.restored }.map(\.id)), nil, nil) }
            let ids = Set(records.filter(\.isInTrash).map(\.id))
            let items = FS.children(of: trash, includeHidden: true).filter { $0.lastPathComponent != ".DS_Store" }
            return (ids, FS.allocatedSize(of: trash), items.count)
        }.value
        reclaimIDsInTrash = result.0
        readable = result.1 != nil
        totalBytes = result.1
        itemCount = result.2
        phase = .done(.now)
    }
}
