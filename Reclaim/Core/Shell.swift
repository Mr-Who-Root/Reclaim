import Foundation

/// Runs command-line tools (docker, brew, git, simctl, lsof…) with a timeout. Never goes through a shell,
/// so arguments are passed exactly as given.
enum Shell {
    struct Output {
        let status: Int32
        let out: String
        let err: String
        var ok: Bool { status == 0 }
    }

    /// Folders where developer tools usually live, added to PATH so tools that call other tools find them.
    static let toolPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/Applications/Docker.app/Contents/Resources/bin",
                            "/usr/bin", "/bin", "/usr/sbin", "/sbin"]

    static func run(_ path: String, _ args: [String], in directory: URL? = nil, env extra: [String: String] = [:],
                    timeout: TimeInterval = 60) -> Output {
        guard FileManager.default.isExecutableFile(atPath: path) else { return Output(status: -1, out: "", err: "\(path) not found") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        if let directory { p.currentDirectoryURL = directory }
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (toolPaths + [env["PATH"] ?? ""]).joined(separator: ":")
        env["HOME"] = FS.home.path
        for (k, v) in extra { env[k] = v }
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return Output(status: -1, out: "", err: error.localizedDescription) }
        let watchdog = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        // Read both pipes concurrently so a chatty stderr can't block stdout.
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        p.waitUntilExit()
        watchdog.cancel()
        return Output(status: p.terminationStatus, out: String(decoding: outData, as: UTF8.self),
                      err: String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The first executable among `candidates`.
    static func find(_ candidates: [String]) -> String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

/// Runs blocking work (file walks, command-line tools) on a dispatch queue rather than Swift's shared worker pool,
/// so quick jobs never wait behind long scans that are holding every pool thread.
func offPool<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: work()) }
    }
}
