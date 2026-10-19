import AppIntents
import Foundation

/// A Reclaim tool, for "Open a Reclaim Tool".
enum ReclaimToolOption: String, AppEnum {
    case home, guided, junk, ai, downloads, duplicates, photos, large, map, security, trash, leftovers, apps, settings

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Reclaim Tool"

    static var caseDisplayRepresentations: [ReclaimToolOption: DisplayRepresentation] = [
        .home: "Mac Overview",
        .guided: "Guided Cleanup",
        .junk: "Junk",
        .ai: "AI Junk",
        .downloads: "Downloads",
        .duplicates: "Duplicates",
        .photos: "Photo Clutter",
        .large: "Large & Old Files",
        .map: "Storage Map",
        .leftovers: "Leftovers",
        .apps: "Uninstall an App",
        .security: "Security Check",
        .trash: "Trash",
        .settings: "Settings",
    ]

    var route: Route { Route(rawValue: rawValue) ?? .home }
}

struct OpenToolIntent: AppIntent {
    static var title: LocalizedStringResource = "Open a Reclaim Tool"
    static var description = IntentDescription("Opens a Reclaim tool so you can review its results.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Tool")
    var tool: ReclaimToolOption

    init() {}
    init(tool: ReclaimToolOption) { self.tool = tool }

    @MainActor
    func perform() async throws -> some IntentResult {
        AppModel.shared.route = tool.route
        return .result()
    }
}

struct OpenGuidedCleanupIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Guided Cleanup"
    static var description = IntentDescription("Opens Reclaim's approval-first cleanup review. Nothing changes until you confirm a final plan.")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        AppModel.shared.route = .guided
        return .result(dialog: "Opening Guided Cleanup. Nothing changes until you confirm a final plan.")
    }
}

struct RunSmartScanIntent: AppIntent {
    static var title: LocalizedStringResource = "Run Smart Scan"
    static var description = IntentDescription("Opens Reclaim and runs every cleanup tool plus a read-only Security Check. You review everything before anything moves.")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let app = AppModel.shared
        app.route = .home
        if app.smartScanRunning {
            return .result(dialog: "Smart Scan is already running in Reclaim.")
        }
        app.startSmartScan()
        return .result(dialog: "Starting Smart Scan in Reclaim. You review every result before anything moves.")
    }
}

struct GetStorageStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Mac Storage Status"
    static var description = IntentDescription("Tells you how much space is free on your startup disk.")

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let v = VolumeStats.startup()
        let text = "\(ByteText.string(v.free)) free of \(ByteText.string(v.total)) (\(Int((v.usedFraction * 100).rounded()))% used)."
        return .result(value: text, dialog: IntentDialog(stringLiteral: text))
    }
}

struct GetReclaimableIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Reclaimable Space"
    static var description = IntentDescription("Tells you how much Reclaim's last Smart Scan found to review.")

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let text: String
        if let snapshot = ReclaimSnapshot.load(), let last = snapshot.lastScan {
            let when = RelativeDateTimeFormatter().localizedString(for: last, relativeTo: .now)
            text = snapshot.reclaimableBytes > 0
                ? "Reclaim's last Smart Scan (\(when)) found \(ByteText.string(snapshot.reclaimableBytes)) to review."
                : "Reclaim's last Smart Scan (\(when)) found nothing to reclaim."
        } else {
            text = "No Smart Scan has run yet. Open Reclaim and run one first."
        }
        return .result(value: text, dialog: IntentDialog(stringLiteral: text))
    }
}

struct ReclaimShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: RunSmartScanIntent(),
                    phrases: ["Run a Smart Scan in \(.applicationName)", "Scan my Mac with \(.applicationName)"],
                    shortTitle: "Smart Scan", systemImageName: "sparkle.magnifyingglass")
        AppShortcut(intent: GetStorageStatusIntent(),
                    phrases: ["Check my Mac storage with \(.applicationName)", "How much space is free in \(.applicationName)"],
                    shortTitle: "Storage Status", systemImageName: "internaldrive")
        AppShortcut(intent: GetReclaimableIntent(),
                    phrases: ["How much can \(.applicationName) reclaim", "Get reclaimable space from \(.applicationName)"],
                    shortTitle: "Reclaimable Space", systemImageName: "arrow.counterclockwise")
        AppShortcut(intent: OpenGuidedCleanupIntent(),
                    phrases: ["Open guided cleanup in \(.applicationName)", "Review my clutter with \(.applicationName)"],
                    shortTitle: "Guided Cleanup", systemImageName: "checklist")
        AppShortcut(intent: OpenToolIntent(),
                    phrases: ["Open \(\.$tool) in \(.applicationName)"],
                    shortTitle: "Open Tool", systemImageName: "square.grid.2x2")
    }
}
