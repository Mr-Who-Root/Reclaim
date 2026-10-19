import SwiftUI

struct RootView: View {
    @Bindable private var app = AppModel.shared

    var body: some View {
        NavigationSplitView {
            Sidebar(selection: $app.route)
                .navigationSplitViewColumnWidth(min: 230, ideal: 250, max: 320)
        } detail: {
            DetailView(route: app.route ?? .home)
                .id(app.route ?? .home)
                .navigationTitle((app.route ?? .home).title)
        }
        .overlay(alignment: .bottom) {
            if let toast = app.toast {
                ToastView(toast: toast,
                          onUndo: { Task { await app.undo(toast) } },
                          onDismiss: { app.toast = nil })
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.35), value: app.toast)
        .themedRoot()
        .sheet(isPresented: $app.showOnboarding) {
            OnboardingView().themedRoot()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            app.refreshVolume()
        }
    }
}

private struct Sidebar: View {
    @Binding var selection: Route?
    @Environment(\.theme) private var theme
    private var app: AppModel { AppModel.shared }

    var body: some View {
        List(selection: $selection) {
            ForEach(Route.Section.allCases.filter { $0 != .pinned }) { section in
                Section {
                    ForEach(Route.visible.filter { $0.section == section }) { route in
                        SidebarRow(route: route).tag(route)
                            .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
                    }
                } header: {
                    Text(section.title)
                        .font(.caption.weight(.bold))
                        .textCase(.uppercase)
                        .tracking(0.6)
                        .foregroundStyle(theme.sidebarSecondaryText.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
                }
            }
        }
        .listStyle(.sidebar)
        .environment(\.defaultMinListRowHeight, 26)
        .safeAreaInset(edge: .top) { BrandHeader() }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 6) {
                Divider().opacity(0.4)
                PinnedSettingsRow(selection: $selection)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "internaldrive.fill").font(.caption).foregroundStyle(.secondary)
                    Text("Macintosh HD").font(.caption.weight(.semibold))
                        .foregroundStyle(theme.sidebarText.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.primary))
                    Spacer()
                    Text("\(Fmt.bytes(app.volume.free)) free").font(.caption).monospacedDigit()
                        .foregroundStyle(theme.sidebarSecondaryText.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
                }
                UsageBar(fraction: app.volume.usedFraction, height: 6)
            }
            .card(padding: 10)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
            .background {
                // Opaque, so list rows scrolling underneath don't show through.
                if theme.isColored {
                    ZStack { ThemeBackground(); theme.sidebarOverlay }.ignoresSafeArea()
                } else {
                    Rectangle().fill(.regularMaterial).ignoresSafeArea()
                }
            }
        }
        .background {
            if theme.isColored {
                ZStack {
                    ThemeBackground()
                    theme.sidebarOverlay
                }
                .ignoresSafeArea()
            }
        }
    }
}

/// Settings, pinned under the sections.
private struct PinnedSettingsRow: View {
    @Binding var selection: Route?
    @Environment(\.theme) private var theme

    var body: some View {
        let selected = selection == .settings
        Button {
            selection = .settings
        } label: {
            HStack(spacing: 9) {
                RouteIcon(route: .settings, side: 24)
                Text(Route.settings.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(selected ? AnyShapeStyle(Color.white) : (theme.sidebarText.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.primary)))
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// App logo and name at the top of the sidebar.
private struct BrandHeader: View {
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: IconRenderer.image(top: theme.accent.nsColor, bottom: theme.accent.deepNSColor, side: 96))
                .resizable()
                .frame(width: 38, height: 38)
                .shadow(color: theme.accentColor.opacity(0.4), radius: 6, y: 2)
            VStack(alignment: .leading, spacing: 0) {
                Text("Reclaim").font(.system(.title3, design: .rounded).weight(.bold))
                    .foregroundStyle(theme.sidebarText.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.primary))
                Text("Disk cleanup, all unlocked").font(.caption)
                    .foregroundStyle(theme.sidebarSecondaryText.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 2)
        .padding(.bottom, 4)
        .accessibilityElement(children: .combine)
    }
}

private struct SidebarRow: View {
    let route: Route
    @Environment(\.theme) private var theme
    private var app: AppModel { AppModel.shared }

    var body: some View {
        HStack(spacing: 9) {
            RouteIcon(route: route, side: 22)
            Text(route.title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .layoutPriority(1)
                .foregroundStyle(theme.sidebarText.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.primary))
            Spacer()
            trailing
        }
    }

    @ViewBuilder private var trailing: some View {
        if let tool = app.tool(for: route) {
            if tool.phase.isScanning {
                ProgressView().controlSize(.mini)
            } else if tool.phase.isDone, tool.reclaimableBytes > 0 {
                Text(Fmt.bytes(tool.reclaimableBytes)).font(.caption.weight(.medium)).monospacedDigit().fixedSize()
                    .foregroundStyle(theme.sidebarSecondaryText.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
            }
        } else if (route == .security && app.security.phase.isScanning) || (route == .map && app.storageMap.phase.isScanning)
                    || (route == .trash && app.trashStatus.phase.isScanning) {
            ProgressView().controlSize(.mini)
        } else if route == .processes, !app.processes.leftBehind.isEmpty {
            Text("\(app.processes.leftBehind.count)").font(.caption.weight(.semibold)).monospacedDigit()
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Capsule().fill(.orange.opacity(0.85))).foregroundStyle(.white)
                .fixedSize()
                .help("Dev processes left running")
        } else if route == .trash, app.trashStatus.waitingBytes > 0 {
            Text(Fmt.bytes(app.trashStatus.waitingBytes)).font(.caption.weight(.medium)).monospacedDigit()
                .foregroundStyle(theme.sidebarSecondaryText.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
        }
    }
}

private struct DetailView: View {
    let route: Route
    var body: some View {
        switch route {
        case .home: HomeView()
        case .guided: GuidedView()
        case .junk: JunkView()
        case .ai: AIJunkView()
        case .docker: DockerView()
        case .dev: DevOverviewView()
        case .toolchains: ToolchainsView()
        case .maintenance: MaintenanceView()
        case .processes: DevProcessesView()
        case .downloads: DownloadsView()
        case .duplicates: DuplicatesView()
        case .photos: PhotosView()
        case .large: LargeFilesView()
        case .map: StorageMapView()
        case .leftovers: AppsView(mode: .leftovers)
        case .apps: AppsView(mode: .uninstall)
        case .security: SecurityView()
        case .trash: TrashView()
        case .settings: SettingsPage()
        }
    }
}
