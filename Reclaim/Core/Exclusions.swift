import Foundation

/// Files and folders the person never wants suggested again. Every tool drops matching results
/// (the path itself and anything inside it) after it scans, and as soon as something is excluded.
@MainActor @Observable
final class Exclusions {
    static let shared = Exclusions()

    private(set) var paths: [String] = UserDefaults.standard.stringArray(forKey: PrefKey.exclusions) ?? []

    var set: Set<String> { Set(paths) }

    func contains(_ path: String) -> Bool { set.containsPathOrAncestor(of: path) }

    /// Excludes a path and removes it from every tool's current results.
    func add(_ url: URL) {
        let path = url.standardizedFileURL.path
        guard !paths.contains(path) else { return }
        paths.append(path)
        paths.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        persist()
        AppModel.shared.applyExclusions()
        AppModel.shared.showToast(Toast(message: String(localized: "Reclaim won't suggest \(url.lastPathComponent) again"),
                                        detail: String(localized: "Manage exclusions in Settings › Exclusions.")))
    }

    func remove(_ path: String) {
        paths.removeAll { $0 == path }
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(paths, forKey: PrefKey.exclusions)
    }
}

extension ScanTool {
    /// Removes excluded paths from this tool's results. Call at the end of `scan()`.
    func dropExcluded() {
        let excluded = Exclusions.shared.set
        if !excluded.isEmpty { forget(paths: excluded) }
    }
}
