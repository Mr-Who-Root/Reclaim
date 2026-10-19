import SwiftUI

struct RootView: View {
    @Bindable private var app = AppModel.shared

    var body: some View {
        NavigationSplitView {
            Sidebar(selection: $app.route)
                .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 300)
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
        .sheet(isPresented: $app.showOnboarding) {
            OnboardingView()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            app.refreshVolume()
        }
    }
}

private struct Sidebar: View {
    @Binding var selection: Route?
    private var app: AppModel { AppModel.shared }

    var body: some View {
        List(selection: $selection) {
            ForEach(Route.Section.allCases) { section in
                Section(section.rawValue) {
                    ForEach(Route.allCases.filter { $0.section == section }) { route in
                        SidebarRow(route: route).tag(route)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Macintosh HD").font(.caption.weight(.semibold))
                    Spacer()
                    Text("\(Fmt.bytes(app.volume.free)) free").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                UsageBar(fraction: app.volume.usedFraction, height: 6)
            }
            .padding(12)
        }
    }
}

private struct SidebarRow: View {
    let route: Route
    private var app: AppModel { AppModel.shared }

    var body: some View {
        HStack(spacing: 8) {
            RouteIcon(route: route, side: 22)
            Text(route.title)
            Spacer()
            trailing
        }
    }

    @ViewBuilder private var trailing: some View {
        if let tool = app.tool(for: route) {
            if tool.phase.isScanning {
                ProgressView().controlSize(.mini)
            } else if tool.phase.isDone, tool.reclaimableBytes > 0 {
                Text(Fmt.bytes(tool.reclaimableBytes)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        } else if route == .security, app.security.phase.isScanning {
            ProgressView().controlSize(.mini)
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
        case .downloads: DownloadsView()
        case .duplicates: DuplicatesView()
        case .photos: PhotosView()
        case .large: LargeFilesView()
        case .map: StorageMapView()
        case .apps: AppsView()
        case .security: SecurityView()
        case .trash: TrashView()
        }
    }
}
