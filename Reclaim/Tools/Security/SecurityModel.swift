import SwiftUI

// Placeholder — replaced by the real implementation.
@MainActor @Observable
final class SecurityModel {
    var phase: ScanPhase = .idle
    /// Items that deserve a look (unsigned, broken signatures, orphaned login items…).
    var attentionCount: Int { 0 }
    func scan() async {}
    func cancelScan() {}
}
