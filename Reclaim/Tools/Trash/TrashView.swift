import SwiftUI

/// Everything Reclaim moved to the Trash, with restore, Open Trash and Empty Trash.
struct TrashView: View {
    private var app: AppModel { AppModel.shared }
    private var log: TrashLog { TrashLog.shared }

    @State private var inTrash: Set<UUID> = []
    @State private var trashSize: Int64?
    @State private var measured = false
    @State private var confirmEmpty = false
    @State private var confirmClear = false
    @State private var emptying = false
    @State private var filter: Filter = .inTrash
    @State private var restoring: Set<UUID> = []

    enum Filter: String, CaseIterable { case inTrash = "Still in Trash", all = "All history", restored = "Restored" }

    var body: some View {
        VStack(spacing: 0) {
            ToolHeader(route: .trash, subtitle: "Finder's Trash is the source of truth for what can still be restored.") {
                Button { FS.openTrash() } label: { Label("Open Trash in Finder", systemImage: "folder") }
                Button(role: .destructive) { confirmEmpty = true } label: {
                    if emptying { ProgressView().controlSize(.small) } else { Label("Empty Trash…", systemImage: "trash.slash") }
                }
                .disabled(emptying)
            }

            HStack(spacing: 12) {
                StatTile(title: "Moved by Reclaim", value: Fmt.bytes(log.totalReclaimed),
                         caption: Fmt.count(log.records.filter { !$0.restored }.count, "item"))
                StatTile(title: "Still recoverable", value: Fmt.bytes(recoverableBytes),
                         caption: "Waiting in the Trash until you empty it", tint: .orange)
                StatTile(title: "Trash size right now", value: trashSize.map(Fmt.bytes) ?? (measured ? "Unknown" : "Measuring…"),
                         caption: trashSize == nil && measured ? "Needs Full Disk Access to measure" : "Everything in the Trash, from any app",
                         tint: .secondary)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)

            if log.records.isEmpty {
                AllClearView(title: "Nothing removed yet",
                             message: "When you move files to the Trash from any tool, they show up here. You can restore them, review them in Finder, and empty the Trash to permanently reclaim the space.")
            } else {
                HStack {
                    ChipPicker(selection: $filter, options: Filter.allCases, label: \.rawValue) { f in
                        records(for: f).count
                    }
                    Spacer()
                    Button("Clear History…") { confirmClear = true }.buttonStyle(.link).padding(.trailing, 20)
                }
                .padding(.bottom, 6)
                list
            }
        }
        .task { await refresh() }
        .confirmationDialog("Empty the Trash?", isPresented: $confirmEmpty) {
            Button("Empty Trash", role: .destructive) { Task { await emptyTrash() } }
        } message: {
            Text("This permanently deletes everything in the Trash, including items other apps put there. It can't be undone.")
        }
        .confirmationDialog("Clear Reclaim's Trash history?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) { log.clearHistory() }
        } message: {
            Text("Only the list is cleared. Nothing in the Trash is touched.")
        }
    }

    private var recoverableBytes: Int64 {
        log.records.filter { inTrash.contains($0.id) }.reduce(0) { $0 + $1.bytes }
    }

    private func records(for filter: Filter) -> [TrashRecord] {
        switch filter {
        case .all: return log.records
        case .inTrash: return log.records.filter { inTrash.contains($0.id) }
        case .restored: return log.records.filter(\.restored)
        }
    }

    private var grouped: [(day: Date, records: [TrashRecord])] {
        let cal = Calendar.current
        let groups = Dictionary(grouping: records(for: filter)) { cal.startOfDay(for: $0.date) }
        return groups.keys.sorted(by: >).map { ($0, groups[$0]!.sorted { $0.date > $1.date }) }
    }

    private var list: some View {
        List {
            ForEach(grouped, id: \.day) { group in
                Section {
                    ForEach(group.records) { record in
                        TrashRow(record: record, inTrash: inTrash.contains(record.id), restoring: restoring.contains(record.id)) {
                            Task { await restore([record.id]) }
                        }
                    }
                } header: {
                    HStack {
                        Text(group.day.formatted(date: .complete, time: .omitted))
                        Spacer()
                        let ids = group.records.filter { inTrash.contains($0.id) }.map(\.id)
                        if ids.count > 1 {
                            Button("Restore All \(ids.count)") { Task { await restore(ids) } }.buttonStyle(.link)
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
        .overlay {
            if records(for: filter).isEmpty {
                Text(filter == .inTrash ? "Nothing Reclaim moved is still in the Trash." : "No items here.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func refresh() async {
        let records = log.records
        let result = await Task.detached(priority: .utility) { () -> (Set<UUID>, Int64?) in
            let ids = Set(records.filter(\.isInTrash).map(\.id))
            return (ids, TrashService.currentTrashSize())
        }.value
        inTrash = result.0
        trashSize = result.1
        measured = true
    }

    private func restore(_ ids: [UUID]) async {
        restoring.formUnion(ids)
        let result = await log.restore(ids)
        restoring.subtract(ids)
        if result.failures.isEmpty {
            app.showToast(Toast(message: "Restored \(Fmt.count(result.restored, "item")) to the original folder"))
        } else {
            app.showToast(Toast(message: "Restored \(result.restored) of \(ids.count)", detail: result.failures.prefix(2).joined(separator: "\n"), isError: true))
        }
        app.refreshVolume()
        await refresh()
    }

    private func emptyTrash() async {
        emptying = true
        let error = await Task.detached { Self.runOsascript("tell application \"Finder\" to empty trash") }.value
        emptying = false
        if let error {
            app.showToast(Toast(message: "The Trash wasn't emptied", detail: error, isError: true))
        } else {
            app.showToast(Toast(message: "Trash emptied", detail: "The space is now free."))
        }
        app.refreshVolume()
        app.writeSnapshot()
        await refresh()
    }

    /// Runs AppleScript out of process so a long empty doesn't block the UI. Returns an error message or nil.
    nonisolated private static func runOsascript(_ source: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return error.localizedDescription
        }
        guard process.terminationStatus == 0 else {
            let data = errPipe.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if text.contains("-1743") { return "Reclaim isn't allowed to control Finder. Allow it in System Settings › Privacy & Security › Automation." }
            return text.isEmpty ? "Finder declined the request." : text
        }
        return nil
    }
}

private struct TrashRow: View {
    let record: TrashRecord
    let inTrash: Bool
    let restoring: Bool
    let onRestore: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if inTrash, let url = record.trashedURL {
                FileIconView(url: url, side: 28)
            } else {
                Image(systemName: record.restored ? "arrow.uturn.backward.circle" : "xmark.bin")
                    .font(.title3).foregroundStyle(.secondary).frame(width: 28, height: 28)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(record.name).lineLimit(1).truncationMode(.middle)
                    if let route = record.route { Badge(text: route.title, color: route.color) }
                }
                Text(FS.abbreviate(record.originalURL.deletingLastPathComponent().path))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(record.date.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.secondary)
            Text(Fmt.bytes(record.bytes)).monospacedDigit().frame(width: 80, alignment: .trailing)
            Group {
                if record.restored {
                    Text("Restored").foregroundStyle(.green)
                } else if inTrash {
                    Button(action: onRestore) {
                        if restoring { ProgressView().controlSize(.small) } else { Text("Restore") }
                    }
                    .help("Restores this item to its original folder")
                } else {
                    Text("Emptied").foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .frame(width: 80, alignment: .trailing)
        }
        .padding(.vertical, 2)
        .contextMenu {
            if inTrash, let url = record.trashedURL { Button("Show in Trash") { FS.reveal([url]) } }
            Button("Show Original Folder") { FS.open(record.originalURL.deletingLastPathComponent()) }
        }
    }
}
