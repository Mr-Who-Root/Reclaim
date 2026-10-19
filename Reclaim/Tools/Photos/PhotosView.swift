import SwiftUI
import QuickLook

struct PhotosView: View {
    @Bindable private var model = AppModel.shared.photos
    @State private var preview: URL?

    var body: some View {
        VStack(spacing: 0) {
            ToolHeader(route: .photos, subtitle: subtitle) {
                if hasResults || model.phase.isScanning {
                    HStack(spacing: 8) {
                        ScopeMenu(scope: $model.scope, defaultsLabel: PhotosModel.defaultsLabel)
                            .disabled(model.phase.isScanning)
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
        if model.phase.isDone, hasResults {
            return "\(Fmt.bytes(model.reclaimableBytes)) worth reviewing in \(model.scannedScopeLabel)"
        }
        return Route.photos.tagline
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .scanning(let message):
            ScanningPanel(title: "Analysing photos", message: message, onCancel: { model.cancelScan() })
        case .failed(let message):
            AllClearView(title: "The scan didn't finish", message: message, actionTitle: "Try Again") {
                Task { await model.scan() }
            }
        case .idle where !hasResults:
            ToolIntro(route: .photos,
                      title: "Tidy up your photos",
                      message: "Reclaim looks through your Pictures, Desktop, Downloads and Movies for look-alike shots, screenshots, screen recordings and blurry photos. Analysis happens on this Mac with Apple's Vision framework.",
                      bullets: ["Look-alikes are grouped, and the sharpest copy is kept",
                                "Screenshots and recordings are found in 40+ languages",
                                "Your Photos library is never opened or changed"],
                      buttonTitle: "Scan Photos",
                      action: { Task { await model.scan() } }) {
                ScopeMenu(scope: $model.scope, defaultsLabel: PhotosModel.defaultsLabel)
            }
        default:
            if PhotoCategory.allCases.allSatisfy({ model.count(for: $0) == 0 }) {
                AllClearView(title: "No photo clutter found",
                             message: "No look-alikes, screenshots, recordings or blurry shots in \(model.scannedScopeLabel). Scanned \(Fmt.relative(model.lastScan)).") {
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
            ChipPicker(selection: $model.category, options: PhotoCategory.allCases, label: { $0.title },
                       count: { model.count(for: $0) })
                .padding(.vertical, 10)

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(description(for: model.category)).font(.callout).foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(Fmt.bytes(model.bytes(for: model.category))) \(model.category == .lookalikes ? "in extra copies" : "in total")")
                        .font(.caption.weight(.semibold))
                }
                .layoutPriority(1)
                categoryControls
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 10)

            Divider()

            ScrollView {
                categoryContent.padding(20)
            }

            SelectionBar(count: model.selectedCount, bytes: model.selectedBytes, isWorking: model.isTrashing,
                         action: { Task { await model.trashSelected() } }) {
                Text("Click to select · double-click to preview").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func description(for category: PhotoCategory) -> String {
        switch category {
        case .lookalikes:
            return "Shots taken around the same time that look almost the same. The best copy — sharpest, then highest resolution — stays."
        case .screenshots:
            return "Found by name and by the screen-capture flag macOS adds. Screenshots older than \(PhotosModel.staleDays) days are suggested."
        case .recordings:
            return "Screen recordings are often the biggest clutter. Ones older than \(PhotosModel.staleDays) days are suggested."
        case .blurry:
            return "Camera photos that scored low for sharpness. Nothing here is preselected — check each one first."
        }
    }

    @ViewBuilder private var categoryControls: some View {
        HStack(spacing: 8) {
            if model.category == .lookalikes {
                Picker("Sensitivity", selection: Binding(get: { model.sensitivity }, set: { model.setSensitivity($0) })) {
                    ForEach(PhotoSensitivity.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .help(model.sensitivity.help)
            }
            Menu {
                Button("Select All") { model.selectAll(in: model.category) }
                if model.category == .screenshots || model.category == .recordings {
                    Button("Select Older Than \(PhotosModel.staleDays) Days") { model.selectStale(in: model.category) }
                }
                Divider()
                Button("Deselect All") { model.deselectAll(in: model.category) }
            } label: {
                Label("Select", systemImage: "checklist")
            }
            .fixedSize()
        }
    }

    @ViewBuilder private var categoryContent: some View {
        let keepers = model.keeperPaths
        switch model.category {
        case .lookalikes:
            if model.groups.isEmpty {
                emptyCategory("No look-alike photos", "Try the Loose sensitivity to group shots with a bit more movement.")
            } else {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(model.groups) { group in
                        PhotoGroupCard(group: group, keepers: keepers, selected: model.selected,
                                       toggle: { model.toggle($0) },
                                       keep: { model.keep($0, in: group.id) },
                                       preview: { preview = $0.entry.url })
                    }
                }
            }
        case .screenshots, .recordings, .blurry:
            let items = model.items(for: model.category)
            if items.isEmpty {
                emptyCategory("Nothing here", emptyMessage(for: model.category))
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 14, alignment: .top)],
                          alignment: .leading, spacing: 16) {
                    ForEach(items) { item in
                        PhotoTile(item: item, isKeeper: keepers.contains(item.id), isSelected: model.selected.contains(item.id),
                                  detail: tileDetail(item),
                                  toggle: { model.toggle(item) }, keep: nil, preview: { preview = item.entry.url })
                    }
                }
            }
        }
    }

    private func tileDetail(_ item: PhotoItem) -> String {
        switch model.category {
        case .blurry: return "Sharpness \(item.sharpnessScore ?? 0)"
        default: return Fmt.date(item.date)
        }
    }

    private func emptyMessage(for category: PhotoCategory) -> String {
        switch category {
        case .screenshots: return "No screenshots in \(model.scannedScopeLabel)."
        case .recordings: return "No screen recordings in \(model.scannedScopeLabel)."
        case .blurry: return "Every camera photo looks sharp enough."
        case .lookalikes: return ""
        }
    }

    private func emptyCategory(_ title: String, _ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.seal").font(.largeTitle).foregroundStyle(.green)
            Text(title).font(.headline)
            Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}

private struct PhotoGroupCard: View {
    let group: PhotoGroup
    let keepers: Set<String>
    let selected: Set<String>
    let toggle: (PhotoItem) -> Void
    let keep: (PhotoItem) -> Void
    let preview: (PhotoItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(group.items.count) look-alikes").font(.headline)
                    Text("Taken \(Fmt.dateTime(group.date))").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Badge(text: "\(Fmt.bytes(group.wasted)) reclaimable", color: .pink)
            }
            ScrollView(.horizontal, showsIndicators: true) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(group.items) { item in
                        PhotoTile(item: item, isKeeper: keepers.contains(item.id), isSelected: selected.contains(item.id),
                                  detail: item.sharpnessScore.map { "Sharpness \($0)" } ?? "\(item.pixelWidth)×\(item.pixelHeight)",
                                  toggle: { toggle(item) }, keep: { keep(item) }, preview: { preview(item) })
                    }
                }
                .padding(.bottom, 6)
            }
        }
        .card()
    }
}

private struct PhotoTile: View {
    let item: PhotoItem
    let isKeeper: Bool
    let isSelected: Bool
    let detail: String
    let toggle: () -> Void
    let keep: (() -> Void)?
    let preview: () -> Void

    private let side: CGFloat = 150
    private var isVideo: Bool { PhotoAnalysis.videoExtensions.contains(item.entry.ext) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                ThumbnailView(url: item.entry.url, side: side, cornerRadius: 10)
                if isSelected && !isKeeper {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.black.opacity(0.25))
                }
            }
            .frame(width: side, height: side)
            .overlay(alignment: .topLeading) {
                if !isKeeper {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.black.opacity(0.25)))
                        .shadow(radius: 2)
                        .padding(6)
                }
            }
            .overlay(alignment: .topTrailing) {
                if isKeeper {
                    Label("Best", systemImage: "star.fill")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .foregroundStyle(.white)
                        .background(Capsule().fill(.green))
                        .padding(6)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if isVideo {
                    Image(systemName: "play.circle.fill").font(.title3).foregroundStyle(.white).shadow(radius: 2).padding(6)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isSelected && !isKeeper ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.clear), lineWidth: 3)
            }

            Text(item.entry.name).font(.caption).lineLimit(1).truncationMode(.middle)
            HStack {
                Text(Fmt.bytes(item.entry.size)).monospacedDigit()
                Spacer()
                Text(detail)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .frame(width: side)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: preview)
        .onTapGesture { if !isKeeper { toggle() } }
        .contextMenu {
            if !isKeeper {
                Button(isSelected ? "Deselect" : "Select", action: toggle)
                if let keep { Button("Keep This One", action: keep) }
                Divider()
            }
            Button("Quick Look", action: preview)
            Button("Reveal in Finder") { FS.reveal([item.entry.url]) }
            Button("Open") { FS.open(item.entry.url) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.entry.name), \(Fmt.bytes(item.entry.size))\(isKeeper ? ", best copy, kept" : "")")
        .accessibilityValue(isKeeper ? "" : (isSelected ? "Selected for removal" : "Not selected"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Quick Look", preview)
    }
}
