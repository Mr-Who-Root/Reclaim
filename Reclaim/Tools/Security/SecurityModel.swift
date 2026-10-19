import SwiftUI

/// Security Check: a read-only look at who signed each app, what starts by itself, and where downloads came from.
/// It never moves, changes or quarantines anything.
@MainActor @Observable
final class SecurityModel {
    enum DeepPhase: Equatable {
        case idle
        case running(done: Int, total: Int, current: String)
        case done(Date)

        var isRunning: Bool { if case .running = self { return true } else { return false } }
    }

    var phase: ScanPhase = .idle
    var deepPhase: DeepPhase = .idle

    private(set) var apps: [SecurityAppItem] = []
    private(set) var launchItems: [SecurityLaunchItem] = []
    private(set) var origins: [SecurityDownloadOrigin] = []

    private var scanTask: Task<SecurityScanResult?, Never>?
    private var deepTask: Task<Void, Never>?

    /// Items that deserve a look: unsigned or broken signatures, and launch items whose program is missing or untrustworthy.
    var attentionCount: Int {
        apps.filter(\.needsAttention).count + launchItems.filter(\.needsAttention).count
    }

    var appsNeedingAttention: [SecurityAppItem] { apps.filter(\.needsAttention) }
    var deepVerifiedCount: Int { apps.filter(\.signature.deepVerified).count }

    func count(_ status: SecuritySignatureStatus) -> Int {
        apps.filter { $0.signature.status == status }.count
    }

    // MARK: Scan

    func scan() async {
        if phase.isScanning, let scanTask {
            _ = await scanTask.value
            return
        }
        cancelDeepVerify()
        phase = .scanning("Reading signatures…")
        let reporter = ProgressReporter { [weak self] message in
            guard let self, self.phase.isScanning else { return }
            self.phase = .scanning(message)
        }
        let task = Task.detached(priority: .userInitiated) { () -> SecurityScanResult? in
            let result = SecurityScanner.run(progress: reporter)
            return Task.isCancelled ? nil : result
        }
        scanTask = task
        let result = await task.value
        guard scanTask == task else { return }
        scanTask = nil
        if let result {
            apps = result.apps
            launchItems = result.launchItems
            origins = result.origins
            deepPhase = .idle
            phase = .done(.now)
        } else {
            phase = apps.isEmpty ? .idle : .done(.now)
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        cancelDeepVerify()
    }

    // MARK: Deep Verify

    /// Re-checks every app's full contents against its signature. Slower; still read-only.
    func startDeepVerify() {
        guard !deepPhase.isRunning, !apps.isEmpty else { return }
        let targets = apps.map(\.url)
        deepPhase = .running(done: 0, total: targets.count, current: targets.first?.deletingPathExtension().lastPathComponent ?? "")
        deepTask = Task { [weak self] in
            for (i, url) in targets.enumerated() {
                if Task.isCancelled { break }
                await MainActor.run {
                    self?.deepPhase = .running(done: i, total: targets.count, current: url.deletingPathExtension().lastPathComponent)
                }
                let info = await Task.detached(priority: .userInitiated) {
                    SecuritySignatureReader.check(url, deep: true)
                }.value
                if Task.isCancelled { break }
                await MainActor.run {
                    guard let self, let idx = self.apps.firstIndex(where: { $0.url == url }) else { return }
                    self.apps[idx].signature = info
                }
            }
            await MainActor.run {
                guard let self else { return }
                self.deepPhase = Task.isCancelled ? .idle : .done(.now)
            }
        }
    }

    func cancelDeepVerify() {
        deepTask?.cancel()
        deepTask = nil
        if deepPhase.isRunning { deepPhase = .idle }
    }
}
