import SwiftUI
import UserNotifications
import CoreSpotlight

@main
struct ReclaimApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @AppStorage(PrefKey.showMenuBar) private var showMenuBar = true
    @AppStorage(PrefKey.accent) private var accentRaw = Accent.ocean.rawValue

    private var accent: Accent { Accent(rawValue: accentRaw) ?? .ocean }

    var body: some Scene {
        Window("Reclaim", id: "main") {
            RootView()
                .tint(accent.color)
                .frame(minWidth: 940, minHeight: 620)
                .onOpenURL { AppModel.shared.handle(url: $0) }
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    if let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String {
                        SpotlightIndex.handle(identifier: id)
                    }
                }
        }
        .defaultSize(width: 1180, height: 760)
        .commands { ReclaimCommands() }

        Settings {
            SettingsView()
                .tint(accent.color)
        }

        MenuBarExtra(isInserted: $showMenuBar) {
            MenuBarView()
                .tint(accent.color)
        } label: {
            Image(systemName: "internaldrive")
                .accessibilityLabel("Reclaim")
        }
        .menuBarExtraStyle(.window)
    }
}

struct ReclaimCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Smart Scan") { AppModel.shared.startSmartScan() }
                .keyboardShortcut("r", modifiers: [.command])
        }
        CommandMenu("Go") {
            ForEach(Array(Route.allCases.enumerated()), id: \.element) { index, route in
                if index < 9 {
                    Button(route.title) { AppModel.shared.route = route }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command])
                } else {
                    Button(route.title) { AppModel.shared.route = route }
                }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            PrefKey.showMenuBar: true,
            PrefKey.vividWidget: true,
            PrefKey.notifyThresholdGB: 1,
            PrefKey.notifyEnabled: true,
            PrefKey.scheduleFrequency: ScheduleFrequency.weekly.rawValue,
        ])
        MainActor.assumeIsolated {
            AppearanceMode.current.apply()
            IconRenderer.applyDockIcon(tinted: defaults.bool(forKey: PrefKey.dockTint), accent: .current)
            SpotlightIndex.indexTools()
            AppModel.shared.startScheduler()
            AppModel.shared.writeSnapshot()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep running in the menu bar when it's shown, so scheduled scans can continue.
        !UserDefaults.standard.bool(forKey: PrefKey.showMenuBar)
    }

    // Show notifications even while Reclaim is frontmost.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let raw = response.notification.request.content.userInfo["route"] as? String
        await MainActor.run {
            if let raw, let route = Route(rawValue: raw) { AppModel.shared.route = route }
            NSApp.activate()
        }
    }
}
