import SwiftUI
import WidgetKit

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            AppearanceSettings().tabItem { Label("Appearance", systemImage: "paintpalette") }
            ScanSettings().tabItem { Label("Scans", systemImage: "clock.arrow.circlepath") }
            FolderSettings().tabItem { Label("Folders", systemImage: "folder") }
            IntegrationSettings().tabItem { Label("Integrations", systemImage: "puzzlepiece.extension") }
            PrivacySettings().tabItem { Label("Privacy", systemImage: "hand.raised") }
        }
        .frame(width: 600, height: 470)
    }
}

// MARK: - General

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
                        Text("Needs approval in System Settings › Login Items.").font(.caption).foregroundStyle(.orange)
                        Button("Open Login Items") { LoginItem.openSettings() }
                    }
                }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
                Toggle("Show Reclaim in the menu bar", isOn: $showMenuBar)
                Text("The menu bar item shows free space, memory and CPU, with a Smart Scan button. While it's shown, Reclaim keeps running after you close the window so scheduled scans can continue.")
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

// MARK: - Appearance

private struct AppearanceSettings: View {
    @AppStorage(PrefKey.accent) private var accentRaw = Accent.ocean.rawValue
    @AppStorage(PrefKey.dockTint) private var dockTint = false
    @AppStorage(PrefKey.vividWidget) private var vividWidget = true

    private var accent: Accent { Accent(rawValue: accentRaw) ?? .ocean }

    var body: some View {
        Form {
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
        .onChange(of: accentRaw) { _, _ in apply() }
        .onChange(of: dockTint) { _, _ in apply() }
        .onChange(of: vividWidget) { _, _ in AppModel.shared.writeSnapshot() }
    }

    private func apply() {
        IconRenderer.applyDockIcon(tinted: dockTint, accent: accent)
        AppModel.shared.writeSnapshot()
    }
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

// MARK: - Scans

private struct ScanSettings: View {
    @AppStorage(PrefKey.schedule) private var scheduleRaw = ScheduleInterval.off.rawValue
    @AppStorage(PrefKey.notifyThresholdGB) private var thresholdGB = 1
    @State private var notificationsDenied = false

    private var lastScheduled: Date? { UserDefaults.standard.object(forKey: PrefKey.lastScheduledScan) as? Date }

    var body: some View {
        Form {
            Section {
                Picker("Scan automatically", selection: $scheduleRaw) {
                    ForEach(ScheduleInterval.allCases) { Text($0.label).tag($0.rawValue) }
                }
                Picker("Notify me when it finds at least", selection: $thresholdGB) {
                    Text("Any amount").tag(0)
                    Text("1 GB").tag(1)
                    Text("5 GB").tag(5)
                    Text("10 GB").tag(10)
                    Text("25 GB").tag(25)
                }
                .disabled(scheduleRaw == ScheduleInterval.off.rawValue)
                if let lastScheduled {
                    LabeledContent("Last scheduled scan", value: Fmt.dateTime(lastScheduled))
                }
                if notificationsDenied {
                    Text("Notifications are turned off for Reclaim. Turn them on in System Settings › Notifications to hear about scheduled results.")
                        .font(.caption).foregroundStyle(.orange)
                }
            } footer: {
                Text("Scheduled scans run while Reclaim is open or in the menu bar. They only ever find things — nothing is removed automatically.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("Run Smart Scan Now") { AppModel.shared.startSmartScan() }
                    .disabled(AppModel.shared.smartScanRunning)
            }
        }
        .formStyle(.grouped)
        .onChange(of: scheduleRaw) { _, value in
            guard value != ScheduleInterval.off.rawValue else { return }
            Task {
                notificationsDenied = !(await Notifier.requestAuthorization())
                await AppModel.shared.runScheduledScanIfDue()
            }
        }
    }
}

// MARK: - Folders

private struct FolderSettings: View {
    private var store: FolderStore { FolderStore.shared }

    var body: some View {
        Form {
            Section {
                if store.folders.isEmpty {
                    Text("No saved folders yet. Every tool can already scan its default folders or your whole Home folder.")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.folders, id: \.path) { url in
                    HStack {
                        FileIconView(url: url, side: 20)
                        Text(FS.abbreviate(url.path)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button {
                            store.remove(url)
                        } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.plain)
                            .help("Remove from saved folders")
                    }
                }
                Button("Add Folder…") { _ = store.chooseFolder(prompt: "Add") }
            } header: {
                Text("Saved folders")
            } footer: {
                Text("Saved folders appear in every tool's location menu, including folders on external drives.")
                    .font(.caption).foregroundStyle(.secondary)
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
                Text("Open `reclaim://scan` to start Smart Scan, or `reclaim://junk`, `reclaim://duplicates`, `reclaim://guided` and so on to jump to a tool.")
                    .font(.callout).textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Privacy

private struct PrivacySettings: View {
    @State private var fullDisk = FS.hasFullDiskAccess()

    var body: some View {
        Form {
            Section("Access") {
                LabeledContent("Full Disk Access") {
                    Label(fullDisk ? "Granted" : "Not granted", systemImage: fullDisk ? "checkmark.circle.fill" : "minus.circle")
                        .foregroundStyle(fullDisk ? .green : .secondary)
                }
                Text("Optional. It lets Reclaim measure iOS backups, Mail downloads, other apps' containers and the Trash. Everything else works without it.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Open Full Disk Access Settings") { FS.openFullDiskAccessSettings() }
                    Button("Check Again") { fullDisk = FS.hasFullDiskAccess() }
                }
            }
            Section("What Reclaim can do") {
                Label("Scan your Home folder or any folder you choose", systemImage: "checkmark")
                Label("Find large, old, duplicate and look-alike files", systemImage: "checkmark")
                Label("Clean app caches, logs and developer junk", systemImage: "checkmark")
                Label("Find leftovers from apps you've removed", systemImage: "checkmark")
                Label("Ask macOS to move items to the Trash, and restore them", systemImage: "checkmark")
            }
            Section("What it won't do") {
                Label("Delete anything permanently without you emptying the Trash", systemImage: "xmark")
                Label("Remove anything on a schedule — scheduled scans only find", systemImage: "xmark")
                Label("Scan for malware — Security Check reads signatures only", systemImage: "xmark")
                Label("Send anything off your Mac — no account, no network, no analytics", systemImage: "xmark")
            }
        }
        .formStyle(.grouped)
    }
}
