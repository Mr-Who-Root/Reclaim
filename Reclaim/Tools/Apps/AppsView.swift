import SwiftUI
import QuickLook

struct AppsView: View {
    let mode: AppsModel.Mode
    @Bindable private var model = AppModel.shared.apps
    @State private var preview: URL?

    var body: some View {
        VStack(spacing: 0) {
            ToolHeader(route: mode == .uninstall ? .apps : .leftovers, subtitle: subtitle) {
                HStack(spacing: 10) {
                    if model.mode == .leftovers, model.phase.isDone {
                        Button { Task { await model.scan() } } label: { Label("Scan Again", systemImage: "arrow.clockwise") }
                    } else if model.mode == .uninstall {
                        Button { Task { await model.loadApps() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                            .disabled(model.appsLoading)
                    }
                }
            }
            Divider()
            switch model.mode {
            case .uninstall: AppsUninstallPane(model: model, preview: $preview)
            case .leftovers: AppsLeftoversPane(model: model, preview: $preview)
            }
        }
        .quickLookPreview($preview)
        .onAppear { model.mode = mode }
        .task {
            model.mode = mode
            if model.apps.isEmpty { await model.loadApps() }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in
            model.refreshRunning()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in
            model.refreshRunning()
        }
    }

    private var subtitle: String {
        switch model.mode {
        case .uninstall:
            return model.apps.isEmpty ? String(localized: "Remove an app together with the files it leaves in your Library")
                : String(localized: "\(Fmt.count(model.apps.count, "app")) installed · remove one with its support files")
        case .leftovers:
            if model.phase.isDone, !model.leftovers.isEmpty {
                return String(localized: "\(Fmt.count(model.leftovers.count, "potential leftover")) · \(Fmt.bytes(model.reclaimableBytes))")
            }
            return String(localized: "Support files left behind by apps you already removed")
        }
    }
}

// MARK: - Uninstall

private struct AppsUninstallPane: View {
    @Bindable var model: AppsModel
    @Binding var preview: URL?

    var body: some View {
        HStack(spacing: 0) {
            appList.frame(width: 300)
            Divider()
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var appList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search apps", text: $model.appSearch).textFieldStyle(.plain)
                    if !model.appSearch.isEmpty {
                        Button { model.appSearch = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .accessibilityLabel("Clear search")
                    }
                }
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 7).fill(.quaternary.opacity(0.6)))
                Picker("Sort", selection: $model.appSort) {
                    ForEach(AppsModel.AppSort.allCases) { Text(Fmt.loc($0.rawValue)).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .help("Sort apps")
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            if !model.unusedApps.isEmpty {
                Toggle(isOn: $model.unusedOnly) {
                    Text("Unused for 6+ months · \(Fmt.count(model.unusedApps.count, "app")) · \(Fmt.bytes(model.unusedBytes))")
                        .font(.caption)
                }
                .toggleStyle(.checkbox)
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer().frame(height: 8)
            if model.appsLoading && model.apps.isEmpty {
                ProgressView("Finding apps…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $model.selectedAppID) {
                    ForEach(model.visibleApps) { app in
                        AppsListRow(app: app, size: model.appSizes[app.id], running: model.isRunning(app))
                            .tag(app.id)
                    }
                }
                .listStyle(.inset)
                .overlay {
                    if model.visibleApps.isEmpty, !model.appsLoading {
                        ContentUnavailableView.search(text: model.appSearch)
                    }
                }
            }
        }
    }

    @ViewBuilder private var detail: some View {
        if let app = model.selectedApp {
            VStack(spacing: 0) {
                AppsDetailHeader(model: model, app: app)
                Divider()
                if model.supportLoading {
                    ScanningPanel(title: "Finding support files for \(app.name)", message: "Looking through your Library")
                } else {
                    supportList(app)
                }
                SelectionBar(count: model.selectedSupportItems.count, bytes: model.uninstallBytes,
                             actionTitle: model.selectedSupportItems.contains(where: \.isAppBundle) ? "Uninstall" : "Move to Trash",
                             isWorking: model.isWorking,
                             action: { Task { await model.uninstall() } }) {
                    Text("Everything stays recoverable in the Trash until you empty it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        } else {
            ContentUnavailableView {
                Label("Pick an app to uninstall", systemImage: "square.stack.3d.up")
            } description: {
                Text("Reclaim shows the app together with the caches, preferences, containers and other files it keeps in your Library, so nothing is left behind.")
            }
        }
    }

    private func supportList(_ app: InstalledApp) -> some View {
        let grouped = Dictionary(grouping: model.supportItems, by: \.location)
        let order = ["Application"] + AppsScanner.locations.map(\.label)
        let sections = order.filter { grouped[$0] != nil }
        return ScrollView {
          LazyVStack(spacing: 14) {
            if model.supportItems.count <= 1 {
                Text("No support files found in your Library for \(app.name). Only the app itself will be removed.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card(padding: 14)
            }
            ForEach(sections, id: \.self) { location in
                let items = grouped[location] ?? []
                ResultGroupCard {
                    ResultGroupHeader(icon: location == "Application" ? "app.badge" : "folder",
                                      title: location == "Application" ? String(localized: "The app") : Fmt.loc(location),
                                      subtitle: Fmt.count(items.count, "item"),
                                      total: Fmt.bytes(items.reduce(0) { $0 + $1.entry.size }))
                } content: {
                    ForEach(items) { item in
                        FileRow(entry: item.entry,
                                isSelected: model.uninstallSelection.contains(item.id),
                                detail: item.unreadable ? "Size unknown — macOS protects this folder. Full Disk Access lets Reclaim measure it."
                                    : (item.isAppBundle ? item.entry.displayPath : item.entry.parentDisplayPath),
                                badge: item.isAppBundle ? "App" : (item.byName ? "Name match" : (item.unreadable ? "Size unknown" : nil)),
                                badgeColor: item.isAppBundle ? .brown : .orange,
                                toggle: { model.toggleSupport(item) },
                                onQuickLook: { preview = $0 })
                            .help(item.byName ? "Matched by the app's name rather than its bundle identifier, so it isn't selected for you." : item.entry.displayPath)
                    }
                }
            }
          }
          .padding(20)
        }
    }
}

private struct AppsListRow: View {
    let app: InstalledApp
    let size: Int64?
    let running: Bool

    var body: some View {
        HStack(spacing: 10) {
            FileIconView(url: app.url, side: 30)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(app.name).lineLimit(1)
                    if running {
                        Circle().fill(.green).frame(width: 6, height: 6)
                            .accessibilityLabel("Running")
                            .help("Running")
                    }
                }
                Text(app.otherLocation ?? app.version.map { String(localized: "Version \($0)") } ?? (app.bundleID ?? ""))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .help(app.otherLocation.map { "\($0)/\(app.url.lastPathComponent)" } ?? "")
                Text(app.lastUsed.map { String(localized: "Opened \(Fmt.relative($0))") } ?? String(localized: "No record of opening"))
                    .font(.caption2)
                    .foregroundStyle(app.isUnused ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.tertiary))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if let size {
                Text(Fmt.bytes(size)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            } else {
                ProgressView().controlSize(.mini)
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Reveal in Finder") { FS.reveal([app.url]) }
            Button("Open") { FS.open(app.url) }
        }
    }
}

private struct AppsDetailHeader: View {
    let model: AppsModel
    let app: InstalledApp

    var body: some View {
        let running = model.isRunning(app)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                FileIconView(url: app.url, side: 60)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(app.name).font(.title3.weight(.semibold))
                        if running { Badge(text: "Running", color: .green) }
                    }
                    Text([app.version.map { String(localized: "Version \($0)") }, app.bundleID].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Text(FS.abbreviate(app.url.path)).font(.caption).foregroundStyle(.tertiary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(model.appSizes[app.id].map(Fmt.bytes) ?? "Measuring…").font(.title3.weight(.semibold)).monospacedDigit()
                    Text("app size").font(.caption).foregroundStyle(.secondary)
                }
            }
            if running {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("\(app.name) is running. Quit it first so it can be removed cleanly.")
                        .font(.callout)
                    Spacer()
                    if model.quitFailed {
                        Button("Force Quit") { Task { await model.quit(app, force: true) } }
                    }
                    Button("Quit App") { Task { await model.quit(app) } }
                        .buttonStyle(.borderedProminent)
                }
                .card(padding: 10)
            }
        }
        .padding(16)
    }
}

// MARK: - Leftovers

private struct AppsLeftoversPane: View {
    @Bindable var model: AppsModel
    @Binding var preview: URL?
    @State private var expanded: Set<String> = []

    var body: some View {
        switch model.phase {
        case .idle:
            ToolIntro(route: .leftovers,
                      title: "Find potential app leftovers",
                      message: "Reclaim compares the support files in your Library with the apps in your Applications folders, the apps that are running, and every app macOS knows about. You review each exact bundle-identifier match before anything moves to the Trash.",
                      bullets: ["Caches, containers, preferences and saved state", "Nothing is selected for you", "Everything goes to the Trash, so it's recoverable"],
                      buttonTitle: "Scan for Leftovers",
                      action: { Task { await model.scan() } })
        case .scanning(let message):
            ScanningPanel(title: "Looking through your Library", message: message, onCancel: model.cancelScan)
        case .failed(let message):
            ContentUnavailableView("The scan didn't finish", systemImage: "exclamationmark.triangle", description: Text(message))
        case .done:
            if model.leftovers.isEmpty {
                AllClearView(title: "No potential leftovers found",
                             message: "Every support folder Reclaim could check belongs to an app that's still on this Mac.",
                             action: { Task { await model.scan() } })
            } else {
                results
            }
        }
    }

    private var results: some View {
        VStack(spacing: 0) {
            FullDiskAccessBanner(reason: "Other apps' Containers and some Library folders can only be checked with it.")
                .padding(.top, 10)
            HStack {
                Text("Nothing is selected for you. Each group below has no installed app with a matching identifier.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()

            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            ScrollView {
              LazyVStack(spacing: 14) {
                ForEach(model.leftovers) { group in
                    ResultGroupCard {
                        AppsLeftoverHeader(model: model, group: group)
                    } content: {
                        ForEach(group.items) { item in
                            FileRow(entry: item.entry,
                                    isSelected: model.leftoverSelection.contains(item.id),
                                    detail: item.unreadable ? "\(item.location) · size unknown — macOS protects this folder"
                                        : "\(item.location) · \(item.entry.parentDisplayPath)",
                                    badge: item.unreadable ? "Size unknown" : nil,
                                    badgeColor: .orange,
                                    toggle: { model.toggleLeftover(item) },
                                    onQuickLook: { preview = $0 })
                                .padding(.leading, 28)
                        }
                    }
                }
              }
              .padding(20)
            }
            SelectionBar(count: model.selectedLeftoverItems.count, bytes: model.leftoverSelectedBytes,
                         isWorking: model.isWorking,
                         action: { Task { await model.trashLeftovers() } }) {
                Button("Select All") {
                    for g in model.leftovers { model.setGroup(g, selected: true) }
                }
                .disabled(model.leftovers.isEmpty)
                Button("Select None") { model.leftoverSelection.removeAll() }
                    .disabled(model.leftoverSelection.isEmpty)
            }
        }
    }
}

private struct AppsLeftoverHeader: View {
    let model: AppsModel
    let group: LeftoverGroup

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { model.isGroupSelected(group) },
                                     set: { model.setGroup(group, selected: $0) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityLabel(model.isGroupSelected(group) ? "Deselect all support files for \(group.bundleID)" : "Select all support files for \(group.bundleID)")
            Image(systemName: "shippingbox").foregroundStyle(.brown).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(group.bundleID).fontWeight(.medium).textSelection(.enabled)
                Text("No app with this identifier is installed · \(Set(group.items.map(\.location)).sorted().joined(separator: ", "))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(Fmt.count(group.items.count, "item")).font(.caption).foregroundStyle(.secondary)
            Text(Fmt.bytes(group.size)).fontWeight(.medium).monospacedDigit().frame(width: 80, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }
}
