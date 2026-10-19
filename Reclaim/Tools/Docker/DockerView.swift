import SwiftUI

struct DockerView: View {
    @Bindable private var model = AppModel.shared.docker
    @State private var confirming: DockerModel.Group?

    var body: some View {
        VStack(spacing: 0) {
            ToolHeader(route: .docker, subtitle: subtitle) {
                if model.phase.isDone {
                    Button { Task { await model.scan() } } label: { Label("Scan Again", systemImage: "arrow.clockwise") }
                        .disabled(model.runningPrune != nil)
                }
            }
            content
        }
        .alert(confirming?.title ?? "",
               isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
               presenting: confirming) { group in
            Button(group.kind == .unusedVolumes ? String(localized: "Delete \(Fmt.bytes(group.reclaimable))")
                                                : String(localized: "Clear \(Fmt.bytes(group.reclaimable))"), role: .destructive) {
                Task { await model.prune(group) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { group in
            Text(confirmationMessage(for: group))
        }
    }

    private var subtitle: String {
        if model.phase.isDone, model.totalUsed > 0 {
            return String(localized: "Docker uses \(Fmt.bytes(model.totalUsed)) · scanned \(Fmt.relative(model.phase.lastScan))")
        }
        return Route.docker.tagline
    }

    private func confirmationMessage(for group: DockerModel.Group) -> String {
        let command = "docker " + group.command.joined(separator: " ")
        let warning = group.kind == .unusedVolumes
            ? String(localized: "This permanently deletes the data inside these volumes. It doesn't go to the Trash and can't be undone.")
            : String(localized: "Docker deletes these directly. They don't go to the Trash and can't be undone.")
        return String(localized: "Reclaim will run:\n\(command)\n\n\(warning)")
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .idle:
            ToolIntro(route: .docker,
                      title: "Clear out what Docker keeps",
                      message: "Images, stopped containers, volumes and build cache pile up inside Docker's disk image. Reclaim asks Docker what each kind takes up and clears one only when you confirm.",
                      bullets: ["Scanning only reads; nothing changes until you confirm",
                                "Clearing uses Docker's own prune commands",
                                "Running containers and the images they use are never touched"],
                      buttonTitle: "Scan Docker",
                      action: { Task { await model.scan() } })
        case .scanning(let message):
            ScanningPanel(title: "Looking inside Docker", message: message, onCancel: { model.cancelScan() })
        case .failed(let message):
            unavailable(message)
        case .done:
            if model.groups.isEmpty {
                AllClearView(title: "Docker is tidy",
                             message: "No build cache, unused images, stopped containers or orphaned volumes. Scanned \(Fmt.relative(model.phase.lastScan)).",
                             action: { Task { await model.scan() } })
            } else {
                results
            }
        }
    }

    private func unavailable(_ message: String) -> some View {
        VStack(spacing: 14) {
            RouteIcon(route: .docker, side: 64)
            Text(message).font(.title2.weight(.semibold))
            Text(model.availability == .notInstalled
                 ? "Reclaim reads Docker through its command-line tool, which isn't installed on this Mac."
                 : "Start Docker, wait until its engine is running, then scan again.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 440)
            HStack(spacing: 10) {
                if model.availability == .notRunning, model.canOpenDocker {
                    Button { model.openDocker() } label: { Label("Open Docker", systemImage: "play.fill") }
                        .buttonStyle(.pill)
                }
                Button("Scan Again") { Task { await model.scan() } }.buttonStyle(.softGlass)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var results: some View {
        ScrollView {
            VStack(spacing: 14) {
                HStack(spacing: 12) {
                    StatTile(title: "Safe to clear", value: Fmt.bytes(model.reclaimableBytes),
                             caption: String(localized: "Build cache and dangling images"))
                    StatTile(title: "Docker uses", value: Fmt.bytes(model.totalUsed),
                             caption: String(localized: "\(Fmt.count(model.counts.images, "image")) · \(Fmt.count(model.counts.containers, "container")) · \(Fmt.count(model.counts.volumes, "volume"))"),
                             tint: .secondary)
                }
                ForEach(model.groups) { group in
                    DockerGroupCard(group: group, isRunning: model.runningPrune == group.kind,
                                    isDisabled: model.runningPrune != nil) { confirming = group }
                }
                Label("Space freed inside Docker's disk image goes back to macOS as Docker releases it.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(20)
        }
    }
}

private struct DockerGroupCard: View {
    let group: DockerModel.Group
    let isRunning: Bool
    let isDisabled: Bool
    let clear: () -> Void

    private static let shown = 5

    var body: some View {
        ResultGroupCard {
            ResultGroupHeader(icon: group.icon, title: group.title, subtitle: group.explanation, total: Fmt.bytes(group.reclaimable))
        } content: {
            ForEach(group.items.prefix(Self.shown)) { item in
                RowDivider(inset: 34)
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).lineLimit(1).truncationMode(.middle)
                        if !item.detail.isEmpty {
                            Text(item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 12)
                    Text(Fmt.bytes(item.bytes)).font(.callout).monospacedDigit().foregroundStyle(.secondary)
                }
                .padding(.leading, 34)
            }
            if group.items.count > Self.shown {
                RowDivider(inset: 34)
                Text("and \(Fmt.count(group.items.count - Self.shown, "more item"))")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.leading, 34)
            }
            RowDivider(inset: 34)
            HStack(spacing: 10) {
                Badge(text: group.isSafe ? "Safe to clear" : "Check first", color: group.isSafe ? .green : .orange)
                Spacer()
                if isRunning {
                    ProgressView().controlSize(.small)
                    Text("Clearing…").font(.callout).foregroundStyle(.secondary)
                } else {
                    Button(group.kind == .unusedVolumes ? "Delete Volumes…" : "Clear…", action: clear)
                        .buttonStyle(.softGlass)
                        .disabled(isDisabled)
                }
            }
            .padding(.leading, 34)
        }
    }
}
