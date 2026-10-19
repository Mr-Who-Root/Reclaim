import SwiftUI
import AppKit

/// UserDefaults keys.
enum PrefKey {
    static let accent = "accent"
    static let dockTint = "dockTint"
    static let showMenuBar = "showMenuBar"
    static let schedule = "schedule"
    static let notifyThresholdGB = "notifyThresholdGB"
    static let lastScheduledScan = "lastScheduledScan"
    static let lastSmartScan = "lastSmartScan"
    static let didOnboard = "didOnboard"
    static let vividWidget = "vividWidget"
    static let hideDevExplainer = "hideDevExplainer"
    static let savedFolders = "savedFolders"
    static let launchAtLoginPrompted = "launchAtLoginPrompted"
}

/// The six app accents. The whole UI, the widget and (optionally) the Dock icon follow it.
enum Accent: String, CaseIterable, Identifiable {
    case ocean, violet, rose, ember, forest, graphite

    var id: String { rawValue }

    var name: String {
        switch self {
        case .ocean: return "Ocean"
        case .violet: return "Violet"
        case .rose: return "Rose"
        case .ember: return "Ember"
        case .forest: return "Forest"
        case .graphite: return "Graphite"
        }
    }

    var hex: String {
        switch self {
        case .ocean: return "#2F7CF6"
        case .violet: return "#8B5CF6"
        case .rose: return "#E64980"
        case .ember: return "#F2711C"
        case .forest: return "#1F9D55"
        case .graphite: return "#5F6B7A"
        }
    }

    /// Darker partner for gradients.
    var deepHex: String {
        switch self {
        case .ocean: return "#1B4FC4"
        case .violet: return "#5B2FC9"
        case .rose: return "#B0245C"
        case .ember: return "#C2410C"
        case .forest: return "#11663A"
        case .graphite: return "#323A45"
        }
    }

    var color: Color { Color(hex: hex) }
    var deepColor: Color { Color(hex: deepHex) }
    var nsColor: NSColor { NSColor(color) }
    var deepNSColor: NSColor { NSColor(deepColor) }

    static var current: Accent {
        Accent(rawValue: UserDefaults.standard.string(forKey: PrefKey.accent) ?? "") ?? .ocean
    }
}

enum ScheduleInterval: String, CaseIterable, Identifiable {
    case off, daily, weekly
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: return "Off"
        case .daily: return "Daily"
        case .weekly: return "Weekly"
        }
    }
    var seconds: TimeInterval? {
        switch self {
        case .off: return nil
        case .daily: return 86_400
        case .weekly: return 7 * 86_400
        }
    }
    static var current: ScheduleInterval {
        ScheduleInterval(rawValue: UserDefaults.standard.string(forKey: PrefKey.schedule) ?? "") ?? .off
    }
}

/// Folders the person saved for quick use as a scan scope in any tool.
@MainActor @Observable
final class FolderStore {
    static let shared = FolderStore()

    private(set) var folders: [URL] = []

    init() {
        let paths = UserDefaults.standard.stringArray(forKey: PrefKey.savedFolders) ?? []
        folders = paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    func add(_ url: URL) {
        guard !folders.contains(where: { $0.path == url.path }) else { return }
        folders.append(url)
        persist()
    }

    func remove(_ url: URL) {
        folders.removeAll { $0.path == url.path }
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(folders.map(\.path), forKey: PrefKey.savedFolders)
    }

    /// Shows an open panel and returns the chosen folder (also saving it).
    func chooseFolder(prompt: String = "Choose") -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        panel.directoryURL = FS.home
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        add(url)
        return url
    }
}
