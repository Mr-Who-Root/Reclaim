import SwiftUI
import QuickLook

struct DownloadsView: View {
    @Bindable private var model = AppModel.shared.downloads
    @State private var preview: URL?

    var body: some View {
        VStack(spacing: 0) {
            ToolHeader(route: .downloads, subtitle: subtitle) {
                HStack(spacing: 8) {
                    Button {
                        FS.open(FS.downloads)
                    } label: {
                        Label("Open in Finder", systemImage: "folder")
                    }
                    if model.phase.isDone {
                        Button {
                            Task { await model.scan() }
                        } label: {
                            Label("Scan Again", systemImage: "arrow.clockwise")
                        }
                    }
                }
            }
            content
        }
        .quickLookPreview($preview)
    }

    private var subtitle: String {
        guard model.phase.isDone else { return String(localized: "Old installers, archives and stale files in your Downloads") }
        return String(localized: "\(Fmt.bytes(model.totalBytes)) in Downloads · \(Fmt.count(model.items.count, "item")) · scanned \(Fmt.relative(model.phase.lastScan))")
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .idle:
            ToolIntro(route: .downloads,
                      title: "Clear out Downloads",
                      message: "Downloads fills up with installers and archives you no longer need. Scan to see the biggest, oldest items first — each one says why it's a candidate.",
                      bullets: ["Installers you've already used", "Archives you've already opened", "Large files untouched for months"],
                      buttonTitle: "Scan Downloads",
                      action: { Task { await model.scan() } })
        case .scanning(let message):
            ScanningPanel(title: "Measuring your Downloads", message: message, onCancel: { model.cancelScan() })
        case .failed:
            if model.accessDenied { accessDeniedView } else {
                AllClearView(title: "The scan didn't finish", message: "Nothing was changed. Try scanning again.",
                             action: { Task { await model.scan() } })
            }
        case .done:
            if model.items.isEmpty {
                if Exclusions.shared.contains(FS.downloads.standardizedFileURL.path) {
                    AllClearView(title: "Downloads is excluded",
                                 message: "You asked Reclaim never to suggest anything in Downloads. Remove it in Settings › Exclusions to see it here again.",
                                 actionTitle: "Open Exclusions",
                                 action: { AppModel.shared.settingsSection = .exclusions; AppModel.shared.route = .settings })
                } else {
                    AllClearView(title: "Downloads is empty",
                                 message: "There's nothing in your Downloads folder. Scanned \(Fmt.relative(model.phase.lastScan)).",
                                 action: { Task { await model.scan() } })
                }
            } else {
                results
            }
        }
    }

    private var accessDeniedView: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.fill").font(.system(size: 46)).foregroundStyle(.orange.gradient)
            Text("Downloads isn't reachable yet").font(.title2.weight(.semibold))
            Text("macOS blocked access to your Downloads folder. Allow Reclaim under Privacy & Security › Files and Folders (or give it Full Disk Access), then try again. Nothing was changed.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 480)
            HStack {
                Button("Open Privacy Settings") { DownloadsScanner.openPrivacySettings() }
                Button("Try Again") { Task { await model.scan() } }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var results: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ChipPicker(selection: $model.filter, options: DownloadsFilter.allCases,
                           label: { $0.rawValue }, count: { model.count(for: $0) })
                Picker("Sort", selection: $model.sort) {
                    ForEach(DownloadsSort.allCases) { Text(Fmt.loc($0.rawValue)).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .padding(.trailing, 20)
            }
            .padding(.bottom, 8)

            let visible = model.visibleItems
            if visible.isEmpty {
                AllClearView(title: "No matches for this filter",
                             message: "Nothing in Downloads fits “\(model.filter.rawValue)”. Try another filter.")
            } else {
                List(visible) { item in
                    FileRow(entry: item.entry,
                            isSelected: model.selection.contains(item.id),
                            detail: item.reason ?? "Added \(Fmt.relative(item.added ?? item.entry.modified))",
                            badge: item.badge?.text,
                            badgeColor: item.badge?.color ?? .secondary,
                            toggle: { model.toggle(item) },
                            onQuickLook: { preview = $0 })
                }
                .listStyle(.inset)
            }

            SelectionBar(count: model.selection.count, bytes: model.selectedBytes,
                         isWorking: model.isTrashing,
                         action: { Task { await model.trashSelected() } }) {
                Button {
                    model.selectSuggested()
                } label: {
                    Label("Select Suggested", systemImage: "wand.and.stars")
                }
                .help("Installers and archives older than 30 days, and large files older than six months")
                .disabled(model.itemCount == 0)
                Menu("More") {
                    Button("Select Everything Shown") { model.selectAllVisible() }
                    Button("Select None") { model.selectNone() }
                }
                .fixedSize()
            }
        }
    }
}
