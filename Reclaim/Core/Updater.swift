import AppKit
import CryptoKit

/// Checks GitHub Releases for a newer Reclaim and installs it in place.
/// The only network request Reclaim makes; it can be turned off in Settings.
@MainActor @Observable
final class Updater {
    static let shared = Updater()

    static let repo = "Mr-Who-Root/Reclaim"

    struct Release: Equatable {
        let version: String
        let notes: String
        let publishedAt: Date?
        let pageURL: URL
        let zipURL: URL
        let zipSize: Int64
        /// "sha256:<hex>" as published by GitHub for the asset, when available.
        let zipDigest: String?
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case downloading(Double)
        case installing
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var lastCheck: Date? = UserDefaults.standard.object(forKey: PrefKey.lastUpdateCheck) as? Date

    var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    var availableRelease: Release? {
        if case .available(let r) = state { return r }
        return nil
    }

    private var timer: Timer?

    // MARK: Checking

    /// Checks shortly after launch and then once a day, when automatic checks are on.
    func startAutomaticChecks() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            Task { @MainActor in await Updater.shared.checkIfDue() }
        }
        Task {
            try? await Task.sleep(for: .seconds(8))
            await checkIfDue()
        }
    }

    private func checkIfDue() async {
        guard UserDefaults.standard.object(forKey: PrefKey.autoCheckUpdates) as? Bool ?? true else { return }
        if let lastCheck, Date().timeIntervalSince(lastCheck) < 20 * 3600 { return }
        await check(userInitiated: false)
    }

    /// Asks GitHub for the latest release and compares it with this build.
    func check(userInitiated: Bool) async {
        if case .downloading = state { return }
        if state == .installing { return }
        state = .checking
        do {
            let release = try await Self.fetchLatest()
            lastCheck = .now
            UserDefaults.standard.set(lastCheck, forKey: PrefKey.lastUpdateCheck)
            guard let release, Self.isNewer(release.version, than: currentVersion) else {
                state = .upToDate
                return
            }
            state = .available(release)
            // Tell the person once per version when the check ran in the background.
            if !userInitiated, UserDefaults.standard.string(forKey: PrefKey.notifiedUpdateVersion) != release.version {
                UserDefaults.standard.set(release.version, forKey: PrefKey.notifiedUpdateVersion)
                Notifier.post(title: String(localized: "Reclaim \(release.version) is available"),
                              body: String(localized: "Open Settings › About to see what's new and install it."),
                              route: .settings)
            }
        } catch {
            state = userInitiated ? .failed(Self.describe(error)) : .idle
        }
    }

    private static func fetchLatest() async throws -> Release? {
        // For testing the install flow against a local release description.
        if let feed = ProcessInfo.processInfo.environment["RECLAIM_UPDATE_FEED"] {
            return try parse(Data(contentsOf: URL(fileURLWithPath: feed)))
        }
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Reclaim/\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0")", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 404 { return nil }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw UpdateError.server }
        return try parse(data)
    }

    private static func parse(_ data: Data) throws -> Release? {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:)) else { throw UpdateError.server }
        let assets = json["assets"] as? [[String: Any]] ?? []
        // The universal app as a zip (the DMG is for people installing by hand).
        guard let zip = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".zip") == true }),
              let zipURL = (zip["browser_download_url"] as? String).flatMap(URL.init(string:)) else { throw UpdateError.noAsset }
        let iso = ISO8601DateFormatter()
        return Release(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag,
                       notes: json["body"] as? String ?? "",
                       publishedAt: (json["published_at"] as? String).flatMap { iso.date(from: $0) },
                       pageURL: page, zipURL: zipURL,
                       zipSize: (zip["size"] as? NSNumber)?.int64Value ?? 0,
                       zipDigest: zip["digest"] as? String)
    }

    /// "1.10.0" > "1.9.2"
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }
        let b = current.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: Installing

    /// Downloads, verifies and swaps in the new version, then relaunches.
    func install() async {
        guard let release = availableRelease else { return }
        state = .downloading(0)
        do {
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("ReclaimUpdate-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let zip = work.appendingPathComponent("Reclaim.zip")
            try await download(release.zipURL, to: zip, expected: release.zipSize)

            state = .installing
            let newApp = try await Task.detached(priority: .userInitiated) { () -> URL in
                try Self.verify(zip: zip, digest: release.zipDigest)
                return try Self.unpack(zip: zip, into: work, expectVersion: release.version)
            }.value
            try Self.launchSwap(newApp: newApp, replacing: Bundle.main.bundleURL)
            NSApp.terminate(nil)
        } catch {
            state = .failed(Self.describe(error))
        }
    }

    private func download(_ url: URL, to file: URL, expected: Int64) async throws {
        if url.isFileURL {
            try FileManager.default.copyItem(at: url, to: file)
            state = .downloading(1)
            return
        }
        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw UpdateError.server }
        let total = max(expected, response.expectedContentLength, 1)
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        var buffer = Data()
        buffer.reserveCapacity(1 << 20)
        var written: Int64 = 0
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 1 << 20 {
                try handle.write(contentsOf: buffer)
                written += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                state = .downloading(min(1, Double(written) / Double(total)))
            }
        }
        if !buffer.isEmpty { try handle.write(contentsOf: buffer) }
        state = .downloading(1)
    }

    nonisolated private static func verify(zip: URL, digest: String?) throws {
        guard let digest, digest.hasPrefix("sha256:") else { return }
        let expected = String(digest.dropFirst("sha256:".count)).lowercased()
        let handle = try FileHandle(forReadingFrom: zip)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == expected else { throw UpdateError.checksum }
    }

    /// Unzips with ditto (keeps the bundle's symlinks and signature) and checks it's really the expected Reclaim.
    nonisolated private static func unpack(zip: URL, into dir: URL, expectVersion: String) throws -> URL {
        let out = dir.appendingPathComponent("unpacked", isDirectory: true)
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, out.path])
        guard let app = FS.children(of: out).first(where: { $0.pathExtension == "app" }),
              let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any],
              info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier else { throw UpdateError.invalidApp }
        guard info["CFBundleShortVersionString"] as? String == expectVersion else { throw UpdateError.invalidApp }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        return app
    }

    /// Starts a small script that waits for Reclaim to quit, swaps the bundles (keeping a backup until the
    /// new one is in place) and opens the new version.
    nonisolated private static func launchSwap(newApp: URL, replacing current: URL) throws {
        let parent = current.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else { throw UpdateError.notWritable(parent.path) }
        let script = """
        while /bin/kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do /bin/sleep 0.2; done
        BACKUP="$1.previous-$$"
        /bin/mv "$1" "$BACKUP" || exit 1
        if /bin/mv "$2" "$1"; then
          /usr/bin/xattr -dr com.apple.quarantine "$1" 2>/dev/null
          /bin/rm -rf "$BACKUP"
        else
          /bin/mv "$BACKUP" "$1"
        fi
        /usr/bin/open "$1"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "reclaim-update", current.path, newApp.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
    }

    nonisolated private static func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw UpdateError.invalidApp }
    }

    enum UpdateError: Error {
        case server, noAsset, checksum, invalidApp, notWritable(String)
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case UpdateError.server: return String(localized: "GitHub didn't answer as expected. Try again later.")
        case UpdateError.noAsset: return String(localized: "The latest release has no app download yet.")
        case UpdateError.checksum: return String(localized: "The download didn't match its published checksum, so it wasn't installed.")
        case UpdateError.invalidApp: return String(localized: "The download isn't a valid Reclaim app, so it wasn't installed.")
        case UpdateError.notWritable(let path): return String(localized: "Reclaim can't replace itself in \(path). Download the update from the website instead.")
        default:
            let ns = error as NSError
            if ns.domain == NSURLErrorDomain { return String(localized: "Couldn't reach GitHub. Check your internet connection.") }
            return ns.localizedDescription
        }
    }
}
