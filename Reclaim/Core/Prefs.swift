import SwiftUI
import AppKit

/// UserDefaults keys.
enum PrefKey {
    static let accent = "accent"
    static let dockTint = "dockTint"
    static let showMenuBar = "showMenuBar"
    static let notifyThresholdGB = "notifyThresholdGB"
    static let lastScheduledScan = "lastScheduledScan"
    static let lastSmartScan = "lastSmartScan"
    static let didOnboard = "didOnboard"
    static let vividWidget = "vividWidget"
    static let hideDevExplainer = "hideDevExplainer"
    static let savedFolders = "savedFolders"
    static let launchAtLoginPrompted = "launchAtLoginPrompted"
    static let aiIdleDays = "aiIdleDays"
    static let appearance = "appearance"
    static let themeStyle = "themeStyle"
    static let autoCheckUpdates = "autoCheckUpdates"
    static let exclusions = "exclusions"
    static let lastUpdateCheck = "lastUpdateCheck"
    static let notifiedUpdateVersion = "notifiedUpdateVersion"
    static let language = "language"
    static let scheduleEnabled = "scheduleEnabled"
    static let scheduleFrequency = "scheduleFrequency"
    static let notifyEnabled = "notifyEnabled"
    static let homeAccessBookmark = "homeAccessBookmark"
    static let lastAccessCheck = "lastAccessCheck"
}

/// Light, dark, or follow the Mac.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: LocalizedStringKey {
        switch self {
        case .system: return "Match System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    static var current: AppearanceMode {
        AppearanceMode(rawValue: UserDefaults.standard.string(forKey: PrefKey.appearance) ?? "") ?? .system
    }

    @MainActor
    func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

/// Languages Reclaim ships translations for.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system = "", en
    case zhHans = "zh-Hans", zhHant = "zh-Hant", es, ar, ptBR = "pt-BR", fr, de, ja, ko, ru, it, tr
    case nl, pl, indonesian = "id", vi, th, uk, sv
    case hi, ml, ta
    var id: String { rawValue }

    /// The language's own name, so people can find it whatever language the app is in.
    var nativeName: String {
        switch self {
        case .system: return String(localized: "Match System")
        case .en: return "English"
        case .zhHans: return "简体中文"
        case .zhHant: return "繁體中文"
        case .es: return "Español"
        case .ar: return "العربية"
        case .ptBR: return "Português (Brasil)"
        case .fr: return "Français"
        case .de: return "Deutsch"
        case .ja: return "日本語"
        case .ko: return "한국어"
        case .ru: return "Русский"
        case .it: return "Italiano"
        case .tr: return "Türkçe"
        case .nl: return "Nederlands"
        case .pl: return "Polski"
        case .indonesian: return "Bahasa Indonesia"
        case .vi: return "Tiếng Việt"
        case .th: return "ไทย"
        case .uk: return "Українська"
        case .sv: return "Svenska"
        case .hi: return "हिन्दी"
        case .ml: return "മലയാളം"
        case .ta: return "தமிழ்"
        }
    }

    static var current: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: PrefKey.language) ?? "") ?? .system
    }

    /// Saves the choice (macOS reads `AppleLanguages` at launch) and reopens Reclaim so it takes effect.
    @MainActor
    func applyAndRelaunch() {
        let defaults = UserDefaults.standard
        defaults.set(rawValue, forKey: PrefKey.language)
        if self == .system { defaults.removeObject(forKey: "AppleLanguages") } else { defaults.set([rawValue], forKey: "AppleLanguages") }
        defaults.synchronize()
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        let url = Bundle.main.bundleURL
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in }
            try? await Task.sleep(for: .milliseconds(300))
            NSApp.terminate(nil)
        }
    }
}

/// The six app accents. The whole UI, the widget and (optionally) the Dock icon follow it.
enum Accent: String, CaseIterable, Identifiable {
    case ocean, violet, rose, ember, forest, graphite

    var id: String { rawValue }

    var name: String {
        switch self {
        case .ocean: return String(localized: "Ocean")
        case .violet: return String(localized: "Violet")
        case .rose: return String(localized: "Rose")
        case .ember: return String(localized: "Ember")
        case .forest: return String(localized: "Forest")
        case .graphite: return String(localized: "Graphite")
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

/// How often scheduled scans run when they're turned on.
enum ScheduleFrequency: String, CaseIterable, Identifiable {
    case daily, everyThreeDays, weekly, monthly
    var id: String { rawValue }
    var label: LocalizedStringKey {
        switch self {
        case .daily: return "Every day"
        case .everyThreeDays: return "Every 3 days"
        case .weekly: return "Every week"
        case .monthly: return "Every month"
        }
    }
    var seconds: TimeInterval {
        switch self {
        case .daily: return 86_400
        case .everyThreeDays: return 3 * 86_400
        case .weekly: return 7 * 86_400
        case .monthly: return 30 * 86_400
        }
    }

    static var current: ScheduleFrequency {
        ScheduleFrequency(rawValue: UserDefaults.standard.string(forKey: PrefKey.scheduleFrequency) ?? "") ?? .weekly
    }

    /// The interval to wait between scheduled scans, or nil when they're off.
    static var activeInterval: TimeInterval? {
        UserDefaults.standard.bool(forKey: PrefKey.scheduleEnabled) ? current.seconds : nil
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
