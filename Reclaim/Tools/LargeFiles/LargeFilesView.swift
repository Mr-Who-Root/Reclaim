import SwiftUI
import QuickLook

struct LargeFilesView: View {
    @Bindable private var model = AppModel.shared.large
    @State private var preview: URL?

    var body: some View {
        VStack(spacing: 0) {
            ToolHeader(route: .large, subtitle: subtitle) {
                HStack(spacing: 8) {
                    ScopeMenu(scope: $model.scope, defaultsLabel: LargeFilesModel.defaultsLabel)
                        .disabled(model.phase.isScanning)
                    if model.phase.isDone {
                        Button {
                            Task { await model.scan() }
                        } label: {
                            Label("Scan Again", systemImage: "arrow.clockwise")
                        }
                        .fixedSize()
                    }
                }
            }
            content
        }
        .quickLookPreview($preview)
        .onChange(of: model.scope) {
            if model.phase.isDone { Task { await model.scan() } }
        }
    }

    private var subtitle: String {
        guard model.phase.isDone else { return "Big files you may have forgotten about" }
        return "\(Fmt.count(model.items.count, "file")) of 10 MB or more in \(model.scope.label(defaultsLabel: LargeFilesModel.defaultsLabel)) · scanned \(Fmt.relative(model.phase.lastScan))"
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .idle, .failed:
            ToolIntro(route: .large,
                      title: "Scan for large & old files",
                      message: "Scans your Downloads, Movies, Documents and Desktop by default — or your Home folder, or any folder you pick. Filter by size, age and kind to find what's worth removing.",
                      bullets: ["App bundles and photo libraries are never split apart", "Quick Look any file before deciding"],
                      buttonTitle: "Scan for Large Files",
                      action: { Task { await model.scan() } }) {
                ScopeMenu(scope: $model.scope, defaultsLabel: LargeFilesModel.defaultsLabel)
            }
        case .scanning(let message):
            ScanningPanel(title: "Looking for large files", message: message, onCancel: { model.cancelScan() })
        case .done:
            if model.items.isEmpty {
                AllClearView(title: "Nothing that big here",
                             message: "No files of 10 MB or more in \(model.scope.label(defaultsLabel: LargeFilesModel.defaultsLabel)). Scanned \(Fmt.relative(model.phase.lastScan)).",
                             action: { Task { await model.scan() } })
            } else {
                results
            }
        }
    }

    private var results: some View {
        VStack(spacing: 0) {
            filterBar
            ChipPicker(selection: $model.kind, options: model.kindOptions,
                       label: { $0?.rawValue ?? "All Kinds" }, count: { model.count(for: $0) })
                .padding(.bottom, 8)

            let visible = model.visibleItems
            if visible.isEmpty {
                AllClearView(title: "Nothing matches these filters",
                             message: "Try a smaller minimum size, any age, or clear the search.")
            } else if model.viewMode == .list {
                List(visible) { item in
                    FileRow(entry: item.entry,
                            isSelected: model.selection.contains(item.id),
                            detail: "\(item.location) · changed \(Fmt.age(item.entry.modified)) ago",
                            badge: item.kind.rawValue,
                            toggle: { model.toggle(item) },
                            onQuickLook: { preview = $0 })
                }
                .listStyle(.inset)
            } else {
                LargeFilesTable(items: visible, model: model, preview: $preview)
            }

            SelectionBar(count: model.selection.count, bytes: model.selectedBytes,
                         isWorking: model.isTrashing,
                         action: { Task { await model.trashSelected() } }) {
                Text("\(Fmt.count(visible.count, "file")) shown · \(Fmt.bytes(model.visibleBytes))")
                    .font(.caption).foregroundStyle(.secondary)
                Menu("Select") {
                    Button("Everything Shown") { model.selectAllVisible() }
                    Button("None") { model.selectNone() }
                }
                .fixedSize()
            }
        }
        .searchable(text: $model.search, placement: .toolbar, prompt: "Search names and folders")
    }

    private var filterBar: some View {
        HStack(spacing: 10) {
            Picker("Size", selection: $model.minSize) {
                ForEach(LargeMinSize.allCases) { Text($0.label).tag($0) }
            }
            .fixedSize()
            Picker("Age", selection: $model.age) {
                ForEach(LargeAge.allCases) { Text($0.label).tag($0) }
            }
            .fixedSize()
            if model.viewMode == .list {
                Menu {
                    Button("Largest First") { model.sortBy(KeyPathComparator(\LargeItem.size, order: .reverse)) }
                    Button("Oldest First") { model.sortBy(KeyPathComparator(\LargeItem.modifiedSort)) }
                    Button("Newest First") { model.sortBy(KeyPathComparator(\LargeItem.modifiedSort, order: .reverse)) }
                    Button("Name") { model.sortBy(KeyPathComparator(\LargeItem.name)) }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
                .fixedSize()
            }
            Spacer()
            Picker("View", selection: $model.viewMode) {
                ForEach(LargeViewMode.allCases) { mode in
                    Label(mode.rawValue, systemImage: mode.icon).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Switch between list and table view")
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }
}

/// Sortable table: name, kind, size, modified, location.
private struct LargeFilesTable: View {
    let items: [LargeItem]
    @Bindable var model: LargeFilesModel
    @Binding var preview: URL?
    @State private var highlighted: Set<String> = []

    var body: some View {
        Table(items, selection: $highlighted, sortOrder: $model.sortOrder) {
            TableColumn("") { item in
                Toggle("", isOn: Binding(get: { model.selection.contains(item.id) }, set: { _ in model.toggle(item) }))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .accessibilityLabel("Select \(item.name) for removal")
            }
            .width(22)
            TableColumn("Name", value: \.name) { item in
                HStack(spacing: 6) {
                    FileIconView(url: item.entry.url, side: 18)
                    Text(item.name).lineLimit(1).truncationMode(.middle)
                }
            }
            .width(min: 180, ideal: 280)
            TableColumn("Kind", value: \.kindName) { item in
                Text(item.kindName).foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 90)
            TableColumn("Size", value: \.size) { item in
                Text(Fmt.bytes(item.size)).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70, ideal: 90)
            TableColumn("Modified", value: \.modifiedSort) { item in
                Text(Fmt.date(item.entry.modified)).foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 110)
            TableColumn("Location", value: \.location) { item in
                Text(item.location).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            .width(min: 120, ideal: 240)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            let urls = items.filter { ids.contains($0.id) }.map(\.entry.url)
            if !urls.isEmpty {
                Button("Select for Removal") { model.selection.formUnion(ids) }
                Button("Deselect") { model.selection.subtract(ids) }
                Divider()
                if let first = urls.first { Button("Quick Look") { preview = first } }
                Button("Reveal in Finder") { FS.reveal(urls) }
            }
        } primaryAction: { ids in
            if let id = ids.first, let item = items.first(where: { $0.id == id }) { preview = item.entry.url }
        }
    }
}
