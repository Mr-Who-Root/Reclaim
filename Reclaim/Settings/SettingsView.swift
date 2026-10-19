import SwiftUI
import WidgetKit

/// The settings sections, shared by the in-app Settings page and the ⌘, window.
enum SettingsSection: String, CaseIterable, Identifiable {
    case access, exclusions, appearance, language, scans, general, integrations, about
    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .access: return "Granted Folders"
        case .exclusions: return "Exclusions"
        case .appearance: return "Appearance"
        case .language: return "Language"
        case .scans: return "Scheduled Scans"
        case .general: return "Launch at Login"
        case .integrations: return "Integrations"
        case .about: return "About"
        }
    }

    var icon: String {
        switch self {
        case .access: return "folder.badge.person.crop"
        case .exclusions: return "eye.slash"
        case .appearance: return "paintpalette"
        case .language: return "globe"
        case .scans: return "clock.arrow.circlepath"
        case .general: return "power"
        case .integrations: return "puzzlepiece.extension"
        case .about: return "info.circle"
        }
    }

    @ViewBuilder var content: some View {
        switch self {
        case .access: AccessSettings()
        case .exclusions: ExclusionSettings()
        case .appearance: AppearanceSettings()
        case .language: LanguageSettings()
        case .scans: ScanSettings()
        case .general: GeneralSettings()
        case .integrations: IntegrationSettings()
        case .about: AboutSettings()
        }
    }
}

/// ⌘, window.
struct SettingsView: View {
    var body: some View {
        TabView {
            ForEach(SettingsSection.allCases) { section in
                section.content.tabItem { Label(section.title, systemImage: section.icon) }
            }
        }
        .frame(width: 660, height: 560)
    }
}

/// Settings as a page in the main window's sidebar.
struct SettingsPage: View {
    @Bindable private var app = AppModel.shared
    private var section: SettingsSection? { app.settingsSection }

    var body: some View {
        VStack(spacing: 0) {
            ToolHeader(route: .settings)
            HStack(spacing: 0) {
                List(SettingsSection.allCases, selection: $app.settingsSection) { s in
                    Label(s.title, systemImage: s.icon).tag(s)
                }
                .listStyle(.sidebar)
                .frame(width: 200)
                Divider()
                (section ?? .access).content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

// MARK: - Granted folders

private struct AccessSettings: View {
    private var access: AccessCenter { AccessCenter.shared }
    private var store: FolderStore { FolderStore.shared }

    var body: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: access.homeGranted ? "checkmark.shield.fill" : "folder.badge.questionmark")
                        .font(.title).foregroundStyle(access.homeGranted ? .green : .orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(access.homeGranted ? "Home folder granted" : "Grant access to your Home folder")
                            .font(.headline)
                        Text("Reclaim scans what's inside \(FS.home.path): your files, Library caches, app leftovers and the temp folders AI tools use. Grant it once and Reclaim checks every location so macOS can ask about each one now, not mid-scan.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if let last = access.lastChecked {
                            Text("Last checked \(Fmt.relative(last)) · \(access.grantedCount) of \(access.locations.count) locations readable")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        HStack {
                            Button(access.homeGranted ? "Grant Again…" : "Grant Access to \(FS.home.path)…") {
                                Task { await access.grantHomeAccess() }
                            }
                            .buttonStyle(.borderedProminent)
                            Button("Check Everything") { Task { await access.checkAll() } }
                                .disabled(access.isChecking)
                            if access.isChecking { ProgressView().controlSize(.small) }
                        }
                        .padding(.top, 4)
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                LabeledContent {
                    HStack {
                        Label(access.fullDiskAccess ? "Granted" : "Not granted",
                              systemImage: access.fullDiskAccess ? "checkmark.circle.fill" : "minus.circle")
                            .foregroundStyle(access.fullDiskAccess ? .green : .secondary)
                        Button("Open Settings") { FS.openFullDiskAccessSettings() }
                        Button("Recheck") { access.refreshFullDiskAccess() }
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Full Disk Access")
                        Text("Optional. Needed for Mail, iPhone backups, the Trash and other apps' data.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Section("Locations Reclaim scans") {
                ForEach(access.locations) { location in
                    LocationRow(location: location)
                }
            }

            Section {
                ForEach(store.folders, id: \.path) { url in
                    HStack {
                        FileIconView(url: url, side: 20)
                        Text(FS.abbreviate(url.path)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(FS.canList(url) ? "Readable" : "Not readable").font(.caption)
                            .foregroundStyle(FS.canList(url) ? .green : .orange)
                        Button { store.remove(url) } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.plain).help("Remove from granted folders")
                    }
                }
                Button("Add Folder…") { _ = store.chooseFolder(prompt: String(localized: "Grant Access")) }
            } header: {
                Text("Extra folders")
            } footer: {
                Text("Folders outside your Home folder, such as external drives. They appear in every tool's location menu.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct LocationRow: View {
    let location: AccessCenter.Location

    var body: some View {
        HStack(spacing: 10) {
            statusIcon.frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(location.title)
                Text("\(FS.abbreviate(location.url.path)) · \(Text(location.usedBy))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            statusText
        }
    }

    @ViewBuilder private var statusIcon: some View {
        switch location.status {
        case .granted: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .blocked: Image(systemName: "lock.fill").foregroundStyle(.orange)
        case .missing: Image(systemName: "circle.dashed").foregroundStyle(.tertiary)
        case .checking: ProgressView().controlSize(.small)
        case .unknown: Image(systemName: "questionmark.circle").foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder private var statusText: some View {
        switch location.status {
        case .granted: Text("Readable").font(.caption).foregroundStyle(.green)
        case .missing: Text("Not on this Mac").font(.caption).foregroundStyle(.secondary)
        case .checking: Text("Checking…").font(.caption).foregroundStyle(.secondary)
        case .unknown: Text("Not checked").font(.caption).foregroundStyle(.secondary)
        case .blocked:
            Button(location.needsFullDiskAccess ? "Needs Full Disk Access" : "Allow in Privacy Settings") {
                if location.needsFullDiskAccess {
                    FS.openFullDiskAccessSettings()
                } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") {
                    NSWorkspace.shared.open(url)
                }
            }
            .font(.caption)
        }
    }
}

// MARK: - Exclusions

private struct ExclusionSettings: View {
    private var exclusions: Exclusions { Exclusions.shared }

    var body: some View {
        Form {
            Section {
                if exclusions.paths.isEmpty {
                    Text("Nothing excluded yet. Right-click any result and choose Never Suggest This.")
                        .foregroundStyle(.secondary)
                }
                ForEach(exclusions.paths, id: \.self) { path in
                    HStack(spacing: 10) {
                        FileIconView(url: URL(fileURLWithPath: path), side: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(URL(fileURLWithPath: path).lastPathComponent).lineLimit(1)
                            Text(FS.abbreviate(path)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Button {
                            exclusions.remove(path)
                        } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.plain)
                            .help("Suggest this again")
                    }
                }
                Button("Add Folder or File…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = true
                    panel.allowsMultipleSelection = true
                    panel.prompt = String(localized: "Exclude")
                    panel.directoryURL = FS.home
                    if panel.runModal() == .OK { panel.urls.forEach(exclusions.add) }
                }
            } header: {
                Text("Never suggest")
            } footer: {
                Text("Every tool skips these files and folders, and anything inside a folder. Remove one to see it in results again after the next scan.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Appearance

private struct AppearanceSettings: View {
    @AppStorage(PrefKey.themeStyle) private var styleRaw = ThemeStyle.vivid.rawValue
    @AppStorage(PrefKey.appearance) private var appearanceRaw = AppearanceMode.system.rawValue
    @AppStorage(PrefKey.accent) private var accentRaw = Accent.ocean.rawValue
    @AppStorage(PrefKey.dockTint) private var dockTint = false
    @AppStorage(PrefKey.vividWidget) private var vividWidget = true

    private var accent: Accent { Accent(rawValue: accentRaw) ?? .ocean }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    ForEach(ThemeStyle.allCases) { style in
                        StylePreview(style: style, accent: accent, selected: styleRaw == style.rawValue) {
                            styleRaw = style.rawValue
                        }
                    }
                }
                .padding(.vertical, 6)
            } header: {
                Text("Style")
            } footer: {
                Text((ThemeStyle(rawValue: styleRaw) ?? .vivid).detail).font(.caption).foregroundStyle(.secondary)
            }
            Section("Theme") {
                Picker("Appearance", selection: $appearanceRaw) {
                    ForEach(AppearanceMode.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
            }
            Section("Accent") {
                AccentPicker(selection: $accentRaw)
                Text("An accent used across the app, the widget and the Dock icon.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Dock icon") {
                HStack(spacing: 16) {
                    Image(nsImage: dockTint ? IconRenderer.image(top: accent.nsColor, bottom: accent.deepNSColor, side: 128) : NSImage(named: NSImage.applicationIconName) ?? NSImage())
                        .resizable().frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Tint my Dock icon to match", isOn: $dockTint)
                        Text("Off keeps the original Reclaim icon.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section("Widget") {
                Picker("Style", selection: $vividWidget) {
                    Text("Vivid").tag(true)
                    Text("Minimal").tag(false)
                }
                .pickerStyle(.segmented)
            }
        }
        .formStyle(.grouped)
        .onChange(of: appearanceRaw) { _, _ in AppearanceMode.current.apply() }
        .onChange(of: accentRaw) { _, _ in apply() }
        .onChange(of: dockTint) { _, _ in apply() }
        .onChange(of: vividWidget) { _, _ in AppModel.shared.writeSnapshot() }
    }

    private func apply() {
        IconRenderer.applyDockIcon(tinted: dockTint, accent: accent)
        AppModel.shared.writeSnapshot()
    }
}

/// A miniature window showing what a style looks like.
private struct StylePreview: View {
    let style: ThemeStyle
    let accent: Accent
    let selected: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    ThemeBackground()
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 3).fill(theme.sidebarOverlay == .clear ? Color.secondary.opacity(0.12) : theme.sidebarOverlay)
                            .frame(width: 26)
                        VStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 4).fill(theme.cardFill).frame(height: 22)
                            HStack(spacing: 4) {
                                RoundedRectangle(cornerRadius: 4).fill(theme.cardFill)
                                RoundedRectangle(cornerRadius: 4).fill(theme.cardFill)
                            }
                            Capsule().fill(LinearGradient(colors: [accent.color, accent.deepColor], startPoint: .top, endPoint: .bottom))
                                .frame(width: 36, height: 8)
                        }
                    }
                    .padding(6)
                }
                .environment(\.theme, theme)
                .frame(width: 128, height: 82)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(selected ? accent.color : Color.secondary.opacity(0.3), lineWidth: selected ? 2.5 : 1))
                Text(style.label).font(.caption.weight(selected ? .semibold : .regular))
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var theme: Theme { Theme(style: style, accent: accent, dark: scheme == .dark) }
}

/// Six accent swatches.
struct AccentPicker: View {
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 14) {
            ForEach(Accent.allCases) { accent in
                Button {
                    selection = accent.rawValue
                } label: {
                    VStack(spacing: 6) {
                        Circle()
                            .fill(LinearGradient(colors: [accent.color, accent.deepColor], startPoint: .top, endPoint: .bottom))
                            .frame(width: 34, height: 34)
                            .overlay {
                                if selection == accent.rawValue {
                                    Image(systemName: "checkmark").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                                }
                            }
                            .overlay(Circle().strokeBorder(.primary.opacity(selection == accent.rawValue ? 0.5 : 0), lineWidth: 2).padding(-4))
                        Text(accent.name).font(.caption)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(accent.name)
                .accessibilityAddTraits(selection == accent.rawValue ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Language

private struct LanguageSettings: View {
    @State private var pending: AppLanguage?
    private let current = AppLanguage.current

    var body: some View {
        Form {
            Section {
                ForEach(AppLanguage.allCases) { language in
                    Button {
                        if language != current { pending = language }
                    } label: {
                        HStack {
                            Text(language.nativeName)
                            Spacer()
                            if language == current { Image(systemName: "checkmark").foregroundStyle(.tint) }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("App language")
            } footer: {
                Text("Show Reclaim in a specific language, or follow your Mac's setting. Changing the language reopens Reclaim.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Reopen Reclaim in \(pending?.nativeName ?? "")?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            Button("Reopen Now") { pending?.applyAndRelaunch() }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: {
            Text("Scans in progress stop. Your results, history and settings are kept.")
        }
    }
}

// MARK: - Scheduled scans

private struct ScanSettings: View {
    @AppStorage(PrefKey.scheduleEnabled) private var enabled = false
    @AppStorage(PrefKey.scheduleFrequency) private var frequencyRaw = ScheduleFrequency.weekly.rawValue
    @AppStorage(PrefKey.notifyEnabled) private var notify = true
    @AppStorage(PrefKey.notifyThresholdGB) private var thresholdGB = 1
    @State private var notificationsDenied = false

    private var lastScheduled: Date? { UserDefaults.standard.object(forKey: PrefKey.lastScheduledScan) as? Date }

    var body: some View {
        Form {
            Section {
                Toggle("Scan automatically", isOn: $enabled)
                Picker("Frequency", selection: $frequencyRaw) {
                    ForEach(ScheduleFrequency.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .disabled(!enabled)
                if enabled {
                    if let lastScheduled {
                        LabeledContent("Last scheduled scan", value: Fmt.dateTime(lastScheduled))
                        LabeledContent("Next scan", value: Fmt.dateTime(lastScheduled.addingTimeInterval(ScheduleFrequency.current.seconds)))
                    } else {
                        LabeledContent("Next scan", value: String(localized: "Within a few minutes"))
                    }
                }
            } header: {
                Text("Schedule")
            } footer: {
                Text("Scheduled scans run while Reclaim is open or in the menu bar. They only ever find things — nothing is removed automatically.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Notify") {
                Toggle("Notify me when a scan finds something to review", isOn: $notify)
                    .disabled(!enabled)
                Picker("Only when it finds at least", selection: $thresholdGB) {
                    Text("Any amount").tag(0)
                    Text("1 GB").tag(1)
                    Text("5 GB").tag(5)
                    Text("10 GB").tag(10)
                    Text("25 GB").tag(25)
                }
                .disabled(!enabled || !notify)
                if notificationsDenied {
                    Text("Notifications are turned off for Reclaim. Turn them on in System Settings › Notifications.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Section {
                Button("Run Smart Scan Now") { AppModel.shared.startSmartScan() }
                    .disabled(AppModel.shared.smartScanRunning)
            }
        }
        .formStyle(.grouped)
        .onChange(of: enabled) { _, on in
            guard on else { return }
            Task {
                if notify { notificationsDenied = !(await Notifier.requestAuthorization()) }
                await AppModel.shared.runScheduledScanIfDue()
            }
        }
        .onChange(of: notify) { _, on in
            guard on else { return }
            Task { notificationsDenied = !(await Notifier.requestAuthorization()) }
        }
    }
}

// MARK: - Launch at login & menu bar

private struct GeneralSettings: View {
    @AppStorage(PrefKey.showMenuBar) private var showMenuBar = true
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginError: String?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            Section {
                Toggle("Open Reclaim at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        loginError = LoginItem.set(on)
                        launchAtLogin = LoginItem.isEnabled
                    }
                if LoginItem.needsApproval {
                    HStack {
                        Text("Needs approval in System Settings › General › Login Items.").font(.caption).foregroundStyle(.orange)
                        Button("Open Login Items") { LoginItem.openSettings() }
                    }
                }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
            } header: {
                Text("Launch at login")
            } footer: {
                Text("Keeps the menu bar item available after you sign in, so scheduled scans can run.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Menu bar") {
                Toggle("Show Reclaim in the menu bar", isOn: $showMenuBar)
                Text("Free space, memory and CPU at a glance, with a Smart Scan button. While it's shown, Reclaim keeps running after you close the window.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("Show the Welcome Tour Again") {
                    AppModel.shared.showOnboarding = true
                    openWindow(id: "main")
                    NSApp.activate()
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Integrations

private struct IntegrationSettings: View {
    var body: some View {
        Form {
            Section("Shortcuts and Siri") {
                Text("Ask Siri to “Run a Smart Scan in Reclaim”, “Check my Mac storage with Reclaim” or “Open guided cleanup in Reclaim”, or build your own workflows in Shortcuts.")
                    .font(.callout)
                Button("Open Shortcuts") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Shortcuts.app")) }
            }
            Section("Spotlight") {
                Text("Press ⌘ Space and type a tool name such as “Duplicates” or “Storage Map”, then pick the Reclaim result.")
                    .font(.callout)
                Button("Refresh Spotlight Entries") { SpotlightIndex.indexTools() }
            }
            Section("Desktop widget") {
                Text("Control-click the Desktop, choose Edit Widgets, search for Reclaim and drag it out. It shows free space and what the last scan found, and starts a scan with one click.")
                    .font(.callout)
                Button("Reload Widget") { AppModel.shared.writeSnapshot() }
            }
            Section("Links") {
                Text("Open reclaim://scan to start Smart Scan, or reclaim://junk, reclaim://ai, reclaim://guided and so on to jump to a tool.")
                    .font(.callout).textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - About

enum AppInfo {
    static let repoURL = URL(string: "https://github.com/Mr-Who-Root/Reclaim")!
    static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—" }
    static var build: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—" }
    static var architecture: String {
        #if arch(arm64)
        return "Apple silicon (arm64)"
        #else
        return "Intel (x86_64)"
        #endif
    }
}

/// Version check and one-click install from GitHub Releases.
private struct UpdatesSection: View {
    @AppStorage(PrefKey.autoCheckUpdates) private var autoCheck = true
    private var updater: Updater { Updater.shared }

    var body: some View {
        Section {
            switch updater.state {
            case .available(let release):
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("Reclaim \(release.version) is available", systemImage: "arrow.down.circle.fill")
                            .font(.headline).foregroundStyle(.tint)
                        Spacer()
                        Text("You have \(updater.currentVersion)").font(.caption).foregroundStyle(.secondary)
                    }
                    if !release.notes.isEmpty {
                        ScrollView {
                            Text(LocalizedStringKey(release.notes))
                                .font(.callout).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 140)
                    }
                    HStack {
                        Button("Download & Install") { Task { await updater.install() } }.buttonStyle(.pill)
                        Link("Release Notes", destination: release.pageURL)
                        Spacer()
                        Text(Fmt.bytes(release.zipSize)).font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Reclaim downloads the update from GitHub, checks it, replaces this copy and reopens. Your settings and history are kept.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            case .downloading(let progress):
                VStack(alignment: .leading, spacing: 6) {
                    Text("Downloading the update…").font(.callout)
                    ProgressView(value: progress)
                }
            case .installing:
                HStack { ProgressView().controlSize(.small); Text("Checking and installing… Reclaim will reopen.").font(.callout) }
            case .checking:
                HStack { ProgressView().controlSize(.small); Text("Checking for updates…").font(.callout) }
            case .upToDate:
                LabeledContent {
                    Button("Check Again") { Task { await updater.check(userInitiated: true) } }
                } label: {
                    Label("Reclaim is up to date", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
            case .failed(let message):
                VStack(alignment: .leading, spacing: 6) {
                    Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
                    Button("Try Again") { Task { await updater.check(userInitiated: true) } }
                }
            case .idle:
                LabeledContent {
                    Button("Check for Updates") { Task { await updater.check(userInitiated: true) } }
                } label: {
                    Text("Version \(updater.currentVersion)")
                }
            }
            Toggle("Check for updates automatically", isOn: $autoCheck)
            if let last = updater.lastCheck {
                Text("Last checked \(Fmt.relative(last))").font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Updates")
        } footer: {
            Text("Reclaim only goes online to ask GitHub for the latest release. Nothing about your Mac is sent.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct AboutSettings: View {
    @State private var confirmClear = false

    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
                        .resizable().frame(width: 72, height: 72)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Reclaim").font(.title.weight(.bold))
                        Text("Version \(AppInfo.version) (\(AppInfo.build))").foregroundStyle(.secondary)
                        Text("Every tool unlocked. No account, no subscription.").font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            UpdatesSection()
            Section("Details") {
                LabeledContent("Version", value: AppInfo.version)
                LabeledContent("Build", value: AppInfo.build)
                LabeledContent("macOS", value: ProcessInfo.processInfo.operatingSystemVersionString)
                LabeledContent("Architecture", value: AppInfo.architecture)
                LabeledContent("Bundle identifier", value: Bundle.main.bundleIdentifier ?? "—")
                LabeledContent("Data folder") {
                    Button(FS.abbreviate(SharedPaths.support.path)) {
                        try? FileManager.default.createDirectory(at: SharedPaths.support, withIntermediateDirectories: true)
                        FS.open(SharedPaths.support)
                    }
                    .buttonStyle(.link)
                }
            }
            Section("Links") {
                Link("Source code", destination: AppInfo.repoURL)
                Link("Releases and downloads", destination: AppInfo.repoURL.appendingPathComponent("releases"))
                Link("Report a problem", destination: AppInfo.repoURL.appendingPathComponent("issues"))
            }
            Section("What Reclaim can and can't do") {
                Label("Scan your Home folder or any folder you grant", systemImage: "checkmark")
                Label("Find large, old, duplicate and look-alike files", systemImage: "checkmark")
                Label("Clean caches, logs, developer and AI junk", systemImage: "checkmark")
                Label("Ask macOS to move items to the Trash, and restore them", systemImage: "checkmark")
                Label("Never deletes permanently — you empty the Trash yourself", systemImage: "xmark")
                Label("Never removes anything on a schedule", systemImage: "xmark")
                Label("Not antivirus — Security Check reads signatures only", systemImage: "xmark")
                Label("Nothing about your Mac leaves it — no analytics, no uploads", systemImage: "xmark")
            }
            Section {
                Button("Clear Trash History…", role: .destructive) { confirmClear = true }
            } footer: {
                Text("Only Reclaim's list is cleared; nothing in the Trash is touched.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Clear Reclaim's Trash history?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) { TrashLog.shared.clearHistory() }
        }
    }
}
