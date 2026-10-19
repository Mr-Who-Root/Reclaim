import AppKit

/// Docker images, containers, volumes and build cache, read through the docker CLI.
/// Scanning only reads `docker system df -v`; cleanup runs Docker's own prune commands after confirmation.
@MainActor @Observable
final class DockerModel: ScanTool {
    let route: Route = .docker
    var phase: ScanPhase = .idle

    enum Availability: Equatable { case unknown, notInstalled, notRunning, ready }

    struct Item: Identifiable, Hashable {
        let id: String
        let title: String
        let detail: String
        let bytes: Int64
    }

    /// One prunable category.
    struct Group: Identifiable, Hashable {
        enum Kind: String, CaseIterable { case buildCache, danglingImages, unusedImages, stoppedContainers, unusedVolumes }
        let kind: Kind
        var items: [Item]
        /// What Docker says pruning would free (falls back to the items' total).
        var reclaimable: Int64
        var id: String { kind.rawValue }

        var isSafe: Bool { kind == .buildCache || kind == .danglingImages }

        var title: String {
            switch kind {
            case .buildCache: return String(localized: "Build cache")
            case .danglingImages: return String(localized: "Dangling images")
            case .unusedImages: return String(localized: "Unused images")
            case .stoppedContainers: return String(localized: "Stopped containers")
            case .unusedVolumes: return String(localized: "Unused volumes")
            }
        }

        var icon: String {
            switch kind {
            case .buildCache: return "hammer"
            case .danglingImages: return "square.stack.3d.down.forward"
            case .unusedImages: return "square.stack.3d.up"
            case .stoppedContainers: return "shippingbox"
            case .unusedVolumes: return "externaldrive"
            }
        }

        var explanation: String {
            switch kind {
            case .buildCache: return String(localized: "Layers Docker cached while building images. Your next build takes a little longer while it rebuilds them.")
            case .danglingImages: return String(localized: "Untagged image layers left behind when an image was rebuilt or re-pulled. Nothing uses them.")
            case .unusedImages: return String(localized: "Images no container uses. Docker pulls or builds them again when you next need them.")
            case .stoppedContainers: return String(localized: "Containers that have exited. Anything they changed inside themselves is lost when they're removed.")
            case .unusedVolumes: return String(localized: "Volumes no container is attached to. Removing them permanently deletes the data they hold, such as databases.")
            }
        }

        /// The exact command, shown in the confirmation.
        var command: [String] {
            switch kind {
            case .buildCache: return ["builder", "prune", "-f"]
            case .danglingImages: return ["image", "prune", "-f"]
            case .unusedImages: return ["image", "prune", "-a", "-f"]
            case .stoppedContainers: return ["container", "prune", "-f"]
            case .unusedVolumes: return ["volume", "prune", "-a", "-f"]
            }
        }
    }

    private(set) var availability: Availability = .unknown
    private(set) var groups: [Group] = []
    private(set) var totalUsed: Int64 = 0
    private(set) var counts = (images: 0, containers: 0, volumes: 0)
    private(set) var runningPrune: Group.Kind?
    private var scanGeneration: UUID?

    var reclaimableBytes: Int64 { groups.filter(\.isSafe).reduce(0) { $0 + $1.reclaimable } }
    var itemCount: Int { groups.filter(\.isSafe).reduce(0) { $0 + $1.items.count } }

    func scan() async {
        phase = .scanning(String(localized: "Asking Docker what it stores…"))
        let generation = UUID()
        scanGeneration = generation
        let result = await offPool { DockerScanner.scan() }
        guard scanGeneration == generation else { return }
        scanGeneration = nil
        availability = result.availability
        groups = result.groups
        totalUsed = result.totalUsed
        counts = result.counts
        switch result.availability {
        case .notInstalled: phase = .failed(String(localized: "Docker isn't installed"))
        case .notRunning: phase = .failed(String(localized: "Docker isn't running"))
        default: phase = .done(.now)
        }
    }

    func cancelScan() {
        guard scanGeneration != nil else { return }
        scanGeneration = nil
        phase = groups.isEmpty ? .idle : .done(.now)
    }

    // Docker items aren't files, so they don't go through the Trash or Guided Cleanup.
    func suggestions() -> [CleanupSuggestion] { [] }
    func forget(paths: Set<String>) {}

    /// Runs the category's prune command, then rescans.
    func prune(_ group: Group) async {
        guard runningPrune == nil else { return }
        runningPrune = group.kind
        let output = await offPool { DockerCLI.run(group.command, timeout: 600) }
        runningPrune = nil
        if output.status == 0 {
            let freed = DockerCLI.reclaimed(in: output.out)
            AppModel.shared.showToast(Toast(message: String(localized: "\(group.title) cleared"),
                                            detail: freed.map { String(localized: "Docker freed \($0).") }))
        } else {
            AppModel.shared.showToast(Toast(message: String(localized: "Docker didn't finish"),
                                            detail: output.err.isEmpty ? nil : String(output.err.prefix(200)), isError: true))
        }
        await scan()
        AppModel.shared.refreshVolume()
    }

    private static let engineApps = ["/Applications/Docker.app", "/Applications/OrbStack.app", "/Applications/Rancher Desktop.app"]
        .map { URL(fileURLWithPath: $0) }

    /// An app that starts the Docker engine (Docker Desktop, OrbStack or Rancher Desktop), if one is installed.
    var canOpenDocker: Bool { Self.engineApps.contains(where: FS.exists) }

    func openDocker() {
        guard let app = Self.engineApps.first(where: FS.exists) else { return }
        NSWorkspace.shared.open(app)
    }
}

struct DockerScanResult: Sendable {
    var availability: DockerModel.Availability = .notInstalled
    var groups: [DockerModel.Group] = []
    var totalUsed: Int64 = 0
    var counts = (images: 0, containers: 0, volumes: 0)
}

enum DockerScanner {
    static func scan() -> DockerScanResult {
        var result = DockerScanResult()
        #if DEBUG
        // For checking the results screen without a Docker engine: a folder with df-v.json and df.jsonl.
        if let dir = ProcessInfo.processInfo.environment["RECLAIM_DOCKER_FIXTURE"],
           let data = FileManager.default.contents(atPath: dir + "/df-v.json"),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return parse(json, summary: (try? String(contentsOfFile: dir + "/df.jsonl", encoding: .utf8)) ?? "")
        }
        #endif
        guard DockerCLI.path != nil else { return result }
        guard DockerCLI.run(["info", "--format", "{{.ServerVersion}}"], timeout: 15).status == 0 else {
            result.availability = .notRunning
            return result
        }
        result.availability = .ready
        let out = DockerCLI.run(["system", "df", "-v", "--format", "{{json .}}"], timeout: 120)
        guard out.status == 0, let data = out.out.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return result }
        let summary = DockerCLI.run(["system", "df", "--format", "{{json .}}"], timeout: 60)
        return parse(json, summary: summary.out)
    }

    /// Builds the groups from `docker system df -v` (and the per-type summary for reclaimable totals).
    static func parse(_ json: [String: Any], summary: String) -> DockerScanResult {
        var result = DockerScanResult(availability: .ready)
        func list(_ key: String) -> [[String: Any]] { json[key] as? [[String: Any]] ?? [] }
        func str(_ d: [String: Any], _ k: String) -> String { (d[k] as? String) ?? (d[k].map { "\($0)" } ?? "") }

        // Reclaimable per type from the short summary: {"Type":"Images","Reclaimable":"1.2GB (50%)",...}
        var reclaimable: [String: Int64] = [:]
        var used: Int64 = 0
        for line in summary.split(separator: "\n") {
            guard let d = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            let type = str(d, "Type")
            reclaimable[type] = DockerCLI.bytes(str(d, "Reclaimable"))
            used += DockerCLI.bytes(str(d, "Size"))
        }
        result.totalUsed = used

        let images = list("Images")
        let containers = list("Containers")
        let volumes = list("Volumes")
        let cache = list("BuildCache")
        result.counts = (images.count, containers.count, volumes.count)

        // Only counts Docker reports as a number are trusted; "N/A" never makes something look unused.
        func unusedImage(_ d: [String: Any]) -> Bool { Int(str(d, "Containers")) == 0 }
        let dangling = images.filter { str($0, "Repository") == "<none>" && unusedImage($0) }
        let unused = images.filter { str($0, "Repository") != "<none>" && unusedImage($0) }
        func imageItem(_ d: [String: Any]) -> DockerModel.Item {
            let repo = str(d, "Repository"), tag = str(d, "Tag")
            let name = repo == "<none>" ? String(str(d, "ID").replacingOccurrences(of: "sha256:", with: "").prefix(12)) : "\(repo):\(tag)"
            // UniqueSize is what removing the image frees; Size also counts layers shared with other images.
            let size = d["UniqueSize"] != nil ? str(d, "UniqueSize") : str(d, "Size")
            return .init(id: str(d, "ID") + name, title: name, detail: str(d, "CreatedSince"), bytes: DockerCLI.bytes(size))
        }
        let stopped = containers.filter { ["exited", "created", "dead"].contains(str($0, "State").lowercased()) }
        let orphanVolumes = volumes.filter { Int(str($0, "Links")) == 0 }
        let freeCache = cache.filter { str($0, "InUse").lowercased() != "true" }

        func group(_ kind: DockerModel.Group.Kind, _ items: [DockerModel.Item], reclaim: Int64?) -> DockerModel.Group? {
            let total = items.reduce(0) { $0 + $1.bytes }
            let r = reclaim ?? total
            guard !items.isEmpty || r > 0 else { return nil }
            return .init(kind: kind, items: items.sorted { $0.bytes > $1.bytes }, reclaimable: r)
        }
        result.groups = [
            group(.buildCache, freeCache.map { .init(id: str($0, "ID"), title: str($0, "Description").isEmpty ? str($0, "CacheType") : str($0, "Description"),
                                                    detail: str($0, "LastUsedAt"), bytes: DockerCLI.bytes(str($0, "Size"))) },
                  reclaim: reclaimable["Build Cache"]),
            group(.danglingImages, dangling.map(imageItem), reclaim: nil),
            group(.unusedImages, unused.map(imageItem), reclaim: nil),
            group(.stoppedContainers, stopped.map { .init(id: str($0, "ID"), title: str($0, "Names"),
                                                          detail: "\(str($0, "Image")) · \(str($0, "Status"))", bytes: DockerCLI.bytes(str($0, "Size"))) },
                  reclaim: reclaimable["Containers"]),
            group(.unusedVolumes, orphanVolumes.map { .init(id: str($0, "Name"), title: str($0, "Name"), detail: str($0, "Driver"),
                                                           bytes: DockerCLI.bytes(str($0, "Size"))) },
                  reclaim: nil),
        ].compactMap { $0 }
        return result
    }
}

/// Finds and runs the docker CLI (Docker Desktop, OrbStack, Colima and Rancher Desktop all provide one).
enum DockerCLI {
    static var path: String? {
        let candidates = ["/usr/local/bin/docker", "/opt/homebrew/bin/docker",
                          "/Applications/Docker.app/Contents/Resources/bin/docker",
                          FS.home.appendingPathComponent(".orbstack/bin/docker").path,
                          FS.home.appendingPathComponent(".rd/bin/docker").path]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func run(_ args: [String], timeout: TimeInterval) -> (status: Int32, out: String, err: String) {
        guard let path else { return (-1, "", "docker not found") }
        let o = Shell.run(path, args, timeout: timeout)
        return (o.status, o.out, o.err)
    }

    /// Docker's sizes use decimal units: "1.2GB", "512.5MB", "3.1kB", "0B", optionally followed by " (45%)".
    static func bytes(_ text: String) -> Int64 {
        let s = text.split(separator: " ").first.map(String.init) ?? ""
        let units: [(String, Double)] = [("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("kB", 1e3), ("KB", 1e3), ("B", 1)]
        for (suffix, factor) in units where s.hasSuffix(suffix) {
            if let v = Double(s.dropLast(suffix.count)) { return Int64(v * factor) }
        }
        return 0
    }

    /// "Total reclaimed space: 1.2GB" → "1.2 GB"
    static func reclaimed(in output: String) -> String? {
        guard let line = output.split(separator: "\n").last(where: { $0.contains("reclaimed space") }),
              let value = line.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) else { return nil }
        return Fmt.bytes(bytes(value))
    }
}
