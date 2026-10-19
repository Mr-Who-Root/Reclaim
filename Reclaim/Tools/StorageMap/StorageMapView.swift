import SwiftUI
import QuickLook

struct StorageMapView: View {
    @Bindable private var model = AppModel.shared.storageMap
    @State private var preview: URL?
    @State private var pendingTrash: MapNode?

    var body: some View {
        VStack(spacing: 0) {
            ToolHeader(route: .map, subtitle: subtitle) {
                HStack(spacing: 8) {
                    StorageMapTargetMenu(model: model)
                    if model.root != nil, !model.phase.isScanning {
                        Button {
                            Task { await model.scan() }
                        } label: {
                            Label("Rescan", systemImage: "arrow.clockwise")
                        }
                    }
                }
            }
            Divider()
            content
        }
        .quickLookPreview($preview)
        .onChange(of: model.target) { _, _ in
            if model.root != nil, !model.phase.isScanning { Task { await model.scan() } }
        }
        .confirmationDialog(pendingTrash.map { "Move “\($0.name)” (\(Fmt.bytes($0.size))) to the Trash?" } ?? "",
                            isPresented: Binding(get: { pendingTrash != nil }, set: { if !$0 { pendingTrash = nil } }),
                            presenting: pendingTrash) { node in
            Button("Move to Trash", role: .destructive) { Task { await model.trash([node]) } }
            Button("Cancel", role: .cancel) {}
        } message: { node in
            Text(node.isDirectory
                 ? "This moves the whole folder, including \(Fmt.count(node.fileCount, "file")). It stays recoverable in the Trash until you empty it."
                 : "It stays recoverable in the Trash until you empty it.")
        }
    }

    private var subtitle: String {
        if let root = model.root { return "\(root.name) · \(Fmt.bytes(root.size)) mapped" }
        return Route.map.tagline
    }

    @ViewBuilder private var content: some View {
        if model.phase.isScanning {
            ScanningPanel(title: "Mapping \(model.target.label)", message: model.phase.message, onCancel: model.cancelScan)
        } else if let current = model.current {
            mapBody(current)
        } else if case .failed(let message) = model.phase {
            ContentUnavailableView("Couldn't map that folder", systemImage: "exclamationmark.triangle", description: Text(message))
        } else {
            ToolIntro(route: .map,
                      title: "Visualise a folder",
                      message: "Builds a treemap where each tile's size is its share of disk space. Click folders to drill in and find the space hogs.",
                      bullets: ["Right-click any tile to reveal, preview or trash it",
                                "Gather items in the Collector and remove them together",
                                "Folders macOS won't let Reclaim read are shown as unknown, never as empty"],
                      buttonTitle: "Build Map",
                      action: { Task { await model.scan() } }) {
                VStack(spacing: 6) {
                    StorageMapTargetMenu(model: model)
                    if model.target == .startup {
                        Text("Mapping the whole disk is slower, and folders macOS protects will show as unknown.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func mapBody(_ current: MapNode) -> some View {
        let _ = model.revision
        return VStack(spacing: 0) {
            VStack(spacing: 10) {
                StorageMapBreadcrumb(model: model, current: current)
                if !model.unreadable.isEmpty {
                    StorageMapUnknownNote(model: model, current: current)
                }
                HStack(alignment: .top, spacing: 12) {
                    StorageTreemapView(model: model, folder: current,
                                       onQuickLook: { preview = $0 },
                                       onTrash: { pendingTrash = $0 })
                        .frame(minWidth: 360, minHeight: 280)
                    StorageMapSidePanel(model: model, folder: current,
                                        onQuickLook: { preview = $0 },
                                        onTrash: { pendingTrash = $0 })
                        .frame(width: 300)
                }
                StorageMapLegend()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            if !model.collector.isEmpty {
                SelectionBar(count: model.collector.count, bytes: model.collectorBytes,
                             actionTitle: "Move Collector to Trash", isWorking: model.isTrashing,
                             action: { Task { await model.trashCollector() } }) {
                    Button("Clear Collector") { model.clearCollector() }
                }
            }
        }
    }
}

// MARK: - Pieces

private struct StorageMapTargetMenu: View {
    @Bindable var model: StorageMapModel
    var folders = FolderStore.shared

    var body: some View {
        Menu {
            Button("Home folder") { model.target = .home }
            Button("Macintosh HD (slower)") { model.target = .startup }
            if !folders.folders.isEmpty {
                Divider()
                ForEach(folders.folders, id: \.path) { url in
                    Button(FS.abbreviate(url.path)) { model.target = .folder(url) }
                }
            }
            Divider()
            Button("Choose Folder…") {
                if let url = folders.chooseFolder(prompt: "Map") { model.target = .folder(url) }
            }
        } label: {
            Label(model.target.label, systemImage: model.target == .startup ? "internaldrive" : "folder")
        }
        .fixedSize()
        .disabled(model.phase.isScanning)
        .help("Choose which folder to map")
    }
}

private struct StorageMapBreadcrumb: View {
    let model: StorageMapModel
    let current: MapNode

    var body: some View {
        HStack(spacing: 8) {
            Button { model.goUp() } label: { Image(systemName: "chevron.left") }
                .disabled(!model.canGoUp)
                .keyboardShortcut("[", modifiers: .command)
                .help("Back to the enclosing folder (⌘[)")
            // Second shortcut for the same action (⌘↑, like Finder).
            Button("Enclosing Folder") { model.goUp() }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(!model.canGoUp)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(model.breadcrumb.enumerated()), id: \.element.id) { index, crumb in
                        if index > 0 {
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                        }
                        Button(crumb.name) { model.go(to: crumb) }
                            .buttonStyle(.plain)
                            .font(.callout.weight(crumb === current ? .semibold : .regular))
                            .foregroundStyle(crumb === current ? .primary : .secondary)
                    }
                }
            }
            Spacer(minLength: 8)
            Text("\(Fmt.bytes(current.size)) · \(Fmt.count(current.fileCount, "file"))")
                .font(.callout).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}

private struct StorageMapUnknownNote: View {
    let model: StorageMapModel
    let current: MapNode
    @State private var showList = false

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "questionmark.folder").foregroundStyle(.orange)
                Text("\(Fmt.count(model.unreadable.count, "folder")) couldn't be read and \(model.unreadable.count == 1 ? "is" : "are") shown as unknown. Totals exclude \(model.unreadable.count == 1 ? "it" : "them"), so they may be higher than shown.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Show Folders") { showList = true }
                    .controlSize(.small)
                    .popover(isPresented: $showList) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Unreadable folders").font(.headline)
                            Text("macOS didn't let Reclaim list these. Nothing is wrong with them.")
                                .font(.caption).foregroundStyle(.secondary)
                            List(model.unreadable, id: \.self) { path in
                                Text(FS.abbreviate(path)).font(.caption).lineLimit(1).truncationMode(.middle)
                                    .contextMenu { Button("Reveal in Finder") { FS.reveal([URL(fileURLWithPath: path)]) } }
                            }
                            .frame(width: 420, height: 260)
                        }
                        .padding()
                    }
            }
            FullDiskAccessBanner(reason: "Mail, Safari, Messages and other apps' data are unknown without it.")
                .padding(.horizontal, -20)
        }
    }
}

private struct StorageMapSidePanel: View {
    let model: StorageMapModel
    let folder: MapNode
    let onQuickLook: (URL) -> Void
    let onTrash: (MapNode) -> Void

    var body: some View {
        let _ = model.revision
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "Largest in \(folder.name)", subtitle: Fmt.count(folder.children.count, "item"))
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(folder.children.prefix(200)) { node in
                        StorageMapRow(model: model, node: node, parentSize: folder.size)
                            .contextMenu { StorageMapActions(model: model, node: node, onQuickLook: onQuickLook, onTrash: onTrash) }
                    }
                }
            }
            .frame(maxHeight: .infinity)

            if !model.collector.isEmpty {
                Divider()
                HStack {
                    SectionTitle(title: "Collector", subtitle: "\(Fmt.count(model.collector.count, "item")) · \(Fmt.bytes(model.collectorBytes))")
                    Button("Clear") { model.clearCollector() }.controlSize(.small)
                }
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(model.collector) { node in
                            HStack(spacing: 8) {
                                FileIconView(url: node.url, side: 20)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(node.name).font(.callout).lineLimit(1).truncationMode(.middle)
                                    Text(FS.abbreviate(node.url.deletingLastPathComponent().path))
                                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                }
                                Spacer()
                                Text(Fmt.bytes(node.size)).font(.caption).monospacedDigit()
                                Button { model.removeFromCollector(node) } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("Remove from Collector")
                            }
                            .contextMenu {
                                Button("Reveal in Finder") { FS.reveal([node.url]) }
                                Button("Remove from Collector") { model.removeFromCollector(node) }
                            }
                        }
                    }
                }
                .frame(maxHeight: 180)
            } else {
                Text("Right-click a tile and choose Add to Collector to gather items, then remove them together.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .card(padding: 12)
    }
}

private struct StorageMapRow: View {
    let model: StorageMapModel
    let node: MapNode
    let parentSize: Int64

    var body: some View {
        let hovered = model.hoveredID == node.id
        let share = parentSize > 0 ? Double(node.size) / Double(parentSize) : 0
        HStack(spacing: 8) {
            icon.frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(node.name).font(.callout).lineLimit(1).truncationMode(.middle)
                    if model.isCollected(node) { Badge(text: "Collected", color: .red) }
                }
                UsageBar(fraction: node.unreadable ? 0 : share, tint: StorageMapPalette.color(for: node, index: 0), height: 4)
            }
            Spacer(minLength: 4)
            if node.unreadable {
                Text("Unknown").font(.caption).foregroundStyle(.orange)
            } else {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(Fmt.bytes(node.size)).font(.caption.weight(.medium)).monospacedDigit()
                    Text(Fmt.percent(share)).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovered ? AnyShapeStyle(.tint.opacity(0.15)) : AnyShapeStyle(Color.clear)))
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { model.hoveredID = node.id } else if model.hoveredID == node.id { model.hoveredID = nil }
        }
        .onTapGesture { if node.isDirectory { model.drill(into: node) } }
        .help(node.unreadable ? "macOS didn't let Reclaim read this folder, so its size is unknown." : node.isDirectory ? "Click to open" : node.name)
    }

    @ViewBuilder private var icon: some View {
        if node.isAggregate {
            Image(systemName: "ellipsis.circle").font(.title3).foregroundStyle(.secondary)
        } else if node.unreadable {
            Image(systemName: "questionmark.folder").font(.title3).foregroundStyle(.orange)
        } else {
            FileIconView(url: node.url, side: 22)
        }
    }
}

private struct StorageMapLegend: View {
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(StorageMapPalette.legend(), id: \.0) { item in
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2).fill(item.1).frame(width: 10, height: 10)
                        Text(item.0).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("Click a folder to open it · Right-click for actions · ⌘[ to go back")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
    }
}
