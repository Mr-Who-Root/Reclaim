import SwiftUI

/// Five short steps: what Reclaim does, an accent, a real Downloads measurement, the tools, and access.
struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(PrefKey.accent) private var accentRaw = Accent.ocean.rawValue
    @AppStorage(PrefKey.dockTint) private var dockTint = false
    @State private var step = 0
    @State private var downloads: DownloadsMeasure?
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var fullDisk = FS.hasFullDiskAccess()

    private let steps = 5
    private var accent: Accent { Accent(rawValue: accentRaw) ?? .ocean }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                Group {
                    switch step {
                    case 0: welcome
                    case 1: colour
                    case 2: measure
                    case 3: tools
                    default: access
                    }
                }
                .padding(32)
                .frame(maxWidth: .infinity)
            }
            Divider()
            HStack {
                HStack(spacing: 6) {
                    ForEach(0..<steps, id: \.self) { i in
                        Capsule().fill(i == step ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                            .frame(width: i == step ? 18 : 7, height: 7)
                    }
                }
                .accessibilityElement()
                .accessibilityLabel("Step \(step + 1) of \(steps)")
                Spacer()
                if step > 0 { Button("Back") { withAnimation { step -= 1 } } }
                if step < steps - 1 {
                    Button("Skip") { finish(scan: false) }.buttonStyle(.link)
                    Button("Continue") { withAnimation { step += 1 } }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                } else {
                    Button("Finish") { finish(scan: false) }
                    Button("Finish & Run Smart Scan") { finish(scan: true) }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
        }
        .frame(width: 640, height: 560)
        .tint(accent.color)
        .onChange(of: accentRaw) { _, _ in applyIcon() }
        .onChange(of: dockTint) { _, _ in applyIcon() }
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(spacing: 18) {
            Image(nsImage: IconRenderer.image(top: accent.nsColor, bottom: accent.deepNSColor, side: 256))
                .resizable().frame(width: 112, height: 112)
            Text("A calmer Mac, on your terms").font(.largeTitle.weight(.bold))
            Text("Reclaim looks at your Mac, surfaces the few things most worth reviewing, and explains every suggestion. Nothing moves until you say so, and everything goes to the Trash first.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 480)
            VStack(alignment: .leading, spacing: 10) {
                principle("magnifyingglass", "Look first", "Every tool starts with a read-only scan.")
                principle("hand.tap", "Decide yourself", "You pick each item. Suggestions always say why.")
                principle("arrow.uturn.backward", "Change your mind", "Removals go to the Trash, with Undo and a full history.")
                principle("lock.open", "Everything unlocked", "Every tool and feature is included — no plans, no paywall.")
            }
            .frame(maxWidth: 440)
        }
    }

    private var colour: some View {
        VStack(spacing: 18) {
            Text("Pick a colour").font(.largeTitle.weight(.bold))
            Text("The whole app changes with you. You can change it again any time in Settings.")
                .foregroundStyle(.secondary)
            Image(nsImage: IconRenderer.image(top: accent.nsColor, bottom: accent.deepNSColor, side: 256))
                .resizable().frame(width: 128, height: 128)
                .animation(.easeInOut, value: accentRaw)
            AccentPicker(selection: $accentRaw)
            Toggle("Tint my Dock icon to match", isOn: $dockTint).toggleStyle(.switch)
        }
    }

    private var measure: some View {
        VStack(spacing: 18) {
            Text("Your Downloads, measured").font(.largeTitle.weight(.bold))
            Text("A real measurement before anything is asked of you. Nothing was changed.")
                .foregroundStyle(.secondary)
            if let downloads {
                if downloads.readable {
                    HStack(spacing: 12) {
                        StatTile(title: "Downloads", value: Fmt.bytes(downloads.total), caption: Fmt.count(downloads.count, "item"))
                        StatTile(title: "Installers & archives", value: Fmt.bytes(downloads.installerBytes),
                                 caption: Fmt.count(downloads.installers, "file"), tint: .orange)
                        StatTile(title: "Untouched 3+ months", value: Fmt.bytes(downloads.oldBytes),
                                 caption: Fmt.count(downloads.old, "item"), tint: .purple)
                    }
                    .frame(maxWidth: 560)
                    Text("Downloads fills up with installers and archives you no longer need. The Downloads tool shows the biggest, oldest items first.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 480)
                } else {
                    Label("macOS didn't allow Reclaim to read Downloads yet. You can allow it from the Downloads tool later.",
                          systemImage: "lock").foregroundStyle(.secondary)
                }
            } else {
                ProgressView("Measuring your Downloads…")
            }
        }
        .task {
            guard downloads == nil else { return }
            downloads = await Task.detached(priority: .userInitiated) { DownloadsMeasure.run() }.value
        }
    }

    private var tools: some View {
        VStack(spacing: 18) {
            Text("What Reclaim does").font(.largeTitle.weight(.bold))
            Text("Ten tools, one habit: look first, decide yourself, then reclaim.").foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], spacing: 12) {
                ForEach(Route.allCases.filter { $0 != .home && $0 != .settings }) { route in
                    HStack(spacing: 10) {
                        RouteIcon(route: route, side: 30)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(route.title).font(.callout.weight(.semibold))
                            Text(route.tagline).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
            }
            .frame(maxWidth: 560)
        }
    }

    private var access: some View {
        VStack(spacing: 18) {
            Text("Access, your way").font(.largeTitle.weight(.bold))
            Text("Reclaim runs entirely on your Mac. macOS asks before it can read Desktop, Documents and Downloads — just click Allow when a tool asks.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 480)
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: AccessCenter.shared.homeGranted ? "checkmark.circle.fill" : "folder.badge.person.crop").font(.title2)
                        .foregroundStyle(AccessCenter.shared.homeGranted ? .green : .accentColor).frame(width: 30)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Your Home folder").font(.headline)
                        Text("Grant \(FS.home.path) once. Reclaim then checks every location it scans, including the temp folders AI tools use, so macOS asks about each one now.")
                            .font(.callout).foregroundStyle(.secondary)
                        HStack {
                            Button(AccessCenter.shared.homeGranted ? "Granted · Check Again" : "Grant Access to Home Folder…") {
                                Task {
                                    if AccessCenter.shared.homeGranted { await AccessCenter.shared.checkAll() } else { await AccessCenter.shared.grantHomeAccess() }
                                    fullDisk = FS.hasFullDiskAccess()
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            if AccessCenter.shared.isChecking { ProgressView().controlSize(.small) }
                            else if AccessCenter.shared.lastChecked != nil {
                                Text("\(AccessCenter.shared.grantedCount) of \(AccessCenter.shared.locations.count) readable").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: fullDisk ? "checkmark.shield.fill" : "lock.shield").font(.title2)
                        .foregroundStyle(fullDisk ? .green : .orange).frame(width: 30)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Full Disk Access (optional)").font(.headline)
                        Text("Lets Reclaim measure iOS backups, Mail downloads, other apps' leftovers and the Trash. In System Settings, turn on Reclaim in the list.")
                            .font(.callout).foregroundStyle(.secondary)
                        HStack {
                            Button(fullDisk ? "Granted" : "Open Full Disk Access Settings") { FS.openFullDiskAccessSettings() }
                                .disabled(fullDisk)
                            if !fullDisk { Button("Check Again") { fullDisk = FS.hasFullDiskAccess() } }
                        }
                    }
                }
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "power").font(.title2).foregroundStyle(.tint).frame(width: 30)
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Open Reclaim at login", isOn: $launchAtLogin)
                            .onChange(of: launchAtLogin) { _, on in
                                LoginItem.set(on)
                                launchAtLogin = LoginItem.isEnabled
                            }
                        Text("Keeps the menu bar item available after you sign in, so scheduled scans can run. Off unless you say yes.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            .card(padding: 18)
            .frame(maxWidth: 520)
        }
    }

    private func principle(_ icon: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.title3).foregroundStyle(.tint).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func applyIcon() {
        IconRenderer.applyDockIcon(tinted: dockTint, accent: accent)
        AppModel.shared.writeSnapshot()
    }

    private func finish(scan: Bool) {
        UserDefaults.standard.set(true, forKey: PrefKey.didOnboard)
        UserDefaults.standard.set(true, forKey: PrefKey.launchAtLoginPrompted)
        dismiss()
        AppModel.shared.showOnboarding = false
        if scan { AppModel.shared.startSmartScan() }
    }
}

/// Quick, read-only measurement of ~/Downloads for the welcome tour.
struct DownloadsMeasure: Sendable {
    var readable = true
    var total: Int64 = 0
    var count = 0
    var installers = 0
    var installerBytes: Int64 = 0
    var old = 0
    var oldBytes: Int64 = 0

    static func run() -> DownloadsMeasure {
        var m = DownloadsMeasure()
        guard FS.canList(FS.downloads) else { m.readable = false; return m }
        let cutoff = Date().addingTimeInterval(-90 * 86_400)
        for url in FS.children(of: FS.downloads) {
            guard let e = FS.entry(for: url) else { continue }
            m.total += e.size
            m.count += 1
            if FS.installerExtensions.contains(e.ext) || FS.archiveExtensions.contains(e.ext) || e.ext == "app" {
                m.installers += 1
                m.installerBytes += e.size
            }
            if let mod = e.modified, mod < cutoff {
                m.old += 1
                m.oldBytes += e.size
            }
        }
        return m
    }
}
