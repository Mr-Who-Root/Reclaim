import SwiftUI
import QuickLook

struct DuplicatesView: View {
    @Bindable private var model = AppModel.shared.duplicates
    @State private var preview: URL?

    var body: some View {
        VStack(spacing: 0) {
            ToolHeader(route: .duplicates, subtitle: subtitle) {
                if hasResults || model.phase.isScanning {
                    HStack(spacing: 8) {
                        scopeControls
                        Button {
                            Task { await model.scan() }
                        } label: {
                            Label("Scan Again", systemImage: "arrow.clockwise")
                        }
                        .disabled(model.phase.isScanning)
                    }
                }
            }
            Divider()
            content
        }
        .quickLookPreview($preview)
    }

    private var hasResults: Bool { model.lastScan != nil }

    private var subtitle: String {
        if model.phase.isDone, !model.groups.isEmpty {
            return String(localized: "\(Fmt.count(model.groups.count, "set")) of identical files in \(model.scannedScopeLabel) · \(Fmt.bytes(model.reclaimableBytes)) in extra copies")
        }
        return String(localized: "Byte-for-byte identical files. One copy of each always stays.")
    }

    private var scopeControls: some View {
        HStack(spacing: 8) {
            ScopeMenu(scope: $model.scope, defaultsLabel: DuplicatesModel.defaultsLabel)
            Picker("Minimum size", selection: $model.minSize) {
                ForEach(DupMinSize.allCases) { Text("At least \($0.label)").tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .help("Files smaller than this are skipped")
        }
        .disabled(model.phase.isScanning)
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .scanning(let message):
            ScanningPanel(title: "Comparing files", message: message, onCancel: { model.cancelScan() })
        case .failed(let message):
            AllClearView(title: "The scan didn't finish", message: message, actionTitle: "Try Again") {
                Task { await model.scan() }
            }
        case .idle where !hasResults:
            ToolIntro(route: .duplicates,
                      title: "Find duplicate files",
                      message: "Reclaim compares files by size, then by their actual contents, so only true byte-for-byte copies are listed. You choose which copy stays.",
                      bullets: ["Scans Downloads, Desktop & Documents, your Home folder, or any folder",
                                "Matches by size, then a quick fingerprint, then a full SHA-256 check",
                                "The keeper of every set can never be selected"],
                      buttonTitle: "Find Duplicates",
                      action: { Task { await model.scan() } }) {
                scopeControls
            }
        default:
            if model.groups.isEmpty {
                AllClearView(title: "No duplicates found",
                             message: "Every file in \(model.scannedScopeLabel) is unique. Scanned \(Fmt.relative(model.lastScan)).") {
                    Task { await model.scan() }
                }
            } else {
                results
            }
        }
    }

    // MARK: Results

    private var results: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                StatTile(title: "Sets of duplicates", value: model.groups.count.formatted(),
                         caption: "\(model.stats.filesSeen.formatted()) files looked at")
                StatTile(title: "Extra copies", value: model.itemCount.formatted(), caption: "Keepers excluded")
                StatTile(title: "Reclaimable", value: Fmt.bytes(model.reclaimableBytes),
                         caption: "\(Fmt.bytes(model.stats.bytesHashed)) checked byte for byte")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            HStack(spacing: 10) {
                Menu {
                    ForEach(DupKeepRule.allCases) { rule in
                        Button {
                            model.apply(rule)
                        } label: {
                            if rule == model.keepRule { Label(rule.label, systemImage: "checkmark") } else { Text(rule.label) }
                        }
                    }
                } label: {
                    Label("Keep: \(model.keepRule.shortLabel)", systemImage: "star")
                }
                .fixedSize()
                .help("Chooses which copy of every set stays, and selects all the others")

                Menu {
                    Button("Select All but the Keepers") { model.selectAllButKeepers() }
                    Button("Select Copies in a Folder…") { model.chooseFolderAndSelect() }
                    Divider()
                    Button("Clear Selection") { model.clearSelection() }
                } label: {
                    Label("Select", systemImage: "checklist")
                }
                .fixedSize()
                .help("Selects files that match a rule, or clears the current selection")

                Spacer()
                Text("Double-click a file to preview it").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)

            ScrollView {
                LazyVStack(spacing: 14) {
                    ForEach(model.groups) { group in
                        ResultGroupCard {
                            DupGroupHeader(group: group)
                        } content: {
                            ForEach(orderedFiles(group)) { file in
                                RowDivider(inset: 0)
                                DupCopyRow(file: file,
                                           isKeeper: model.isKeeper(file, in: group),
                                           isSelected: model.selected.contains(file.path),
                                           toggle: { model.toggle(file, in: group) },
                                           keep: { model.keep(file, in: group.id) },
                                           selectFolder: { model.selectCopies(in: file.url.deletingLastPathComponent()) },
                                           preview: { preview = file.url })
                            }
                        }
                    }
                }
                .padding(20)
            }

            SelectionBar(count: model.selected.count, bytes: model.selectedBytes, isWorking: model.isTrashing,
                         action: { Task { await model.trashSelected() } }) {
                Text("Keepers stay where they are.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Keeper first, then the rest by path.
    private func orderedFiles(_ group: DuplicateGroup) -> [FileEntry] {
        group.files.sorted { a, b in
            if a.path == group.keeperPath { return true }
            if b.path == group.keeperPath { return false }
            return a.path < b.path
        }
    }
}

private struct DupGroupHeader: View {
    let group: DuplicateGroup

    var body: some View {
        HStack(spacing: 10) {
            if let keeper = group.keeper {
                if showsThumbnail(keeper.url) {
                    ThumbnailView(url: keeper.url, side: 34, cornerRadius: 6)
                } else {
                    FileIconView(url: keeper.url, side: 32)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(group.name).font(.headline).lineLimit(1).truncationMode(.middle).foregroundStyle(.primary)
                Text("\(group.files.count) identical copies · \(Fmt.bytes(group.files.first?.size ?? group.fileSize)) each")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Badge(text: "\(Fmt.bytes(group.wasted)) reclaimable", color: .purple)
        }
        .padding(.vertical, 4)
        .textCase(nil)
    }

    private func showsThumbnail(_ url: URL) -> Bool {
        switch FS.kind(of: url) {
        case .image, .video, .document: return true
        default: return false
        }
    }
}

private struct DupCopyRow: View {
    let file: FileEntry
    let isKeeper: Bool
    let isSelected: Bool
    let toggle: () -> Void
    let keep: () -> Void
    let selectFolder: () -> Void
    let preview: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { isSelected && !isKeeper }, set: { _ in toggle() }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(isKeeper)
                .accessibilityLabel(isKeeper ? "Keeper, never removed" : (isSelected ? "Selected for removal" : "Not selected for removal"))
            FileIconView(url: file.url, side: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(file.parentDisplayPath).lineLimit(1).truncationMode(.middle)
                Text(file.name).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if isKeeper {
                Badge(text: "Keeper", color: .green)
            } else {
                Button("Keep This One", action: keep)
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .help("Keeps this copy and makes the others removable")
            }
            VStack(alignment: .trailing, spacing: 1) {
                Text("Created \(Fmt.date(file.created))").font(.caption).foregroundStyle(.secondary)
                Text("Modified \(Fmt.date(file.modified))").font(.caption2).foregroundStyle(.tertiary)
            }
            .frame(width: 130, alignment: .trailing)
            Text(Fmt.bytes(file.size)).monospacedDigit().frame(width: 74, alignment: .trailing)
        }
        .padding(.vertical, 2)
        .opacity(isKeeper ? 0.9 : 1)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: preview)
        .contextMenu {
            if !isKeeper {
                Button(isSelected ? "Deselect" : "Select", action: toggle)
                Button("Keep This One", action: keep)
            }
            Button("Select All Copies in This Folder", action: selectFolder)
            Divider()
            Button("Quick Look", action: preview)
            Button("Reveal in Finder") { FS.reveal([file.url]) }
            Button("Never Suggest This") { Exclusions.shared.add(file.url) }
            Button("Open") { FS.open(file.url) }
        }
    }
}
