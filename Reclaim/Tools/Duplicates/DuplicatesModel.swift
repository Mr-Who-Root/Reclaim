import SwiftUI

// Placeholder — replaced by the real implementation.
@MainActor @Observable
final class DuplicatesModel: ScanTool {
    let route: Route = .duplicates
    var phase: ScanPhase = .idle
    var reclaimableBytes: Int64 { 0 }
    var itemCount: Int { 0 }
    func scan() async {}
    func cancelScan() {}
    func suggestions() -> [CleanupSuggestion] { [] }
}
