import SwiftUI

struct DevProcessesView: View {
    @Bindable private var model = AppModel.shared.processes
    @State private var confirmQuitAll = false
    @State private var confirming: DevProcessGroup?

    var body: some View {
        VStack(spacing: 0) {
            ToolHeader(route: .processes, subtitle: subtitle) {
                Button { Task { await model.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            }
            content
        }
        .onAppear { model.startLiveUpdates() }
        .onDisappear { model.stopLiveUpdates() }
        .alert("Quit every left-behind process?", isPresented: $confirmQuitAll) {
            Button("Quit All", role: .destructive) {
                Task { await model.quitAllLeftBehind() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Each one is asked to quit normally, so it can save and clean up first. Anything unsaved in them is lost.")
        }
        .alert(confirming.map { String(localized: "Quit \($0.title)?") } ?? "",
               isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
               presenting: confirming) { group in
            Button("Quit", role: .destructive) { Task { await model.quit(group) } }
            Button("Cancel", role: .cancel) {}
        } message: { group in
            Text("It's running from \(group.parentName ?? String(localized: "a terminal")). Stop it there if you're still using it.")
        }
    }

    private var subtitle: String {
        guard model.phase.isDone else { return Route.processes.tagline }
        if model.leftBehind.isEmpty { return String(localized: "Nothing left behind · updates live") }
        return String(localized: "\(Fmt.count(model.leftBehind.count, "process group")) left behind, using \(Fmt.bytes(model.leftBehindMemory)) of memory")
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .idle, .scanning:
            ScanningPanel(title: "Looking at running processes", message: nil)
        case .failed(let message):
            AllClearView(title: "Couldn't read the process list", message: message, action: { Task { await model.refresh() } })
        case .done:
            if model.groups.isEmpty {
                AllClearView(title: "No leftover dev processes",
                             message: "Nothing you started for development is running on its own. Dev servers you run from a terminal show up here while they listen on a port.",
                             actionTitle: "Refresh", action: { Task { await model.refresh() } })
            } else {
                ScrollView {
                    VStack(spacing: 14) {
                        if !model.leftBehind.isEmpty {
                            section(icon: "exclamationmark.bubble", title: String(localized: "Left behind"),
                                    subtitle: String(localized: "The terminal or tool that started these has closed, but they're still running and holding memory."),
                                    groups: model.leftBehind, quitAll: true)
                        }
                        if !model.running.isEmpty {
                            section(icon: "play.circle", title: String(localized: "Dev servers you're running"),
                                    subtitle: String(localized: "Started from a terminal and listening on a port."),
                                    groups: model.running, quitAll: false)
                        }
                        if !model.helpers.isEmpty {
                            section(icon: "gearshape.2", title: String(localized: "Build daemons & helpers"),
                                    subtitle: String(localized: "Gradle, Kotlin and adb keep these running on purpose so the next build or connection is faster. Quitting them is harmless; they start again when needed."),
                                    groups: model.helpers, quitAll: false)
                        }
                        Label("Reclaim only lists processes you own and never quits anything without you asking.", systemImage: "hand.raised")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(20)
                }
            }
        }
    }

    private func section(icon: String, title: String, subtitle: String, groups: [DevProcessGroup], quitAll: Bool) -> some View {
        ResultGroupCard {
            HStack(alignment: .firstTextBaseline) {
                ResultGroupHeader(icon: icon, title: title, subtitle: subtitle,
                                  total: Fmt.bytes(groups.reduce(0) { $0 + $1.memory }))
                if quitAll, groups.count > 1 {
                    Button("Quit All…") { confirmQuitAll = true }
                        .buttonStyle(.softGlass)
                        .disabled(!model.quitting.isEmpty)
                }
            }
        } content: {
            ForEach(groups) { group in
                RowDivider(inset: 34)
                DevProcessRow(group: group, isQuitting: model.quitting.contains(group.id), isStubborn: model.stubborn.contains(group.id),
                              quit: {
                                  if group.status == .running { confirming = group } else { Task { await model.quit(group) } }
                              },
                              forceQuit: { Task { await model.quit(group, force: true) } },
                              reveal: { model.revealFolder(group) },
                              copy: { model.copyCommand(group) })
                    .padding(.leading, 34)
            }
        }
    }
}

private struct DevProcessRow: View {
    let group: DevProcessGroup
    let isQuitting: Bool
    let isStubborn: Bool
    let quit: () -> Void
    let forceQuit: () -> Void
    let reveal: () -> Void
    let copy: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon).font(.title3).foregroundStyle(.tint).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(group.title).lineLimit(1).truncationMode(.middle)
                if !group.detail.isEmpty {
                    Text(group.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                HStack(spacing: 6) {
                    Text(meta).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                    ForEach(group.ports.prefix(3), id: \.self) { port in
                        if let url = URL(string: "http://localhost:\(port)") {
                            Link("localhost:\(String(port))", destination: url).font(.caption)
                        }
                    }
                }
            }
            .help(group.commandLine)
            Spacer(minLength: 12)
            Text(Fmt.bytes(group.memory)).font(.callout).monospacedDigit().foregroundStyle(.secondary)
            if isQuitting {
                ProgressView().controlSize(.small).frame(width: 60)
            } else if isStubborn {
                Button("Force Quit", action: forceQuit).buttonStyle(.pillDestructive)
            } else {
                Button("Quit", action: quit).buttonStyle(.softGlass)
            }
        }
        .contextMenu {
            Button("Copy Command", action: copy)
            if group.root.cwd != nil { Button("Show Folder in Finder", action: reveal) }
        }
    }

    private var meta: String {
        var parts = ["PID \(group.root.pid)", String(localized: "started \(Fmt.relative(group.root.started))")]
        if group.members.count > 1 { parts.append(Fmt.count(group.members.count, "process", "processes")) }
        if group.status == .running, let parent = group.parentName { parts.append(String(localized: "from \(parent)")) }
        return parts.joined(separator: " · ")
    }

    private var icon: String {
        switch group.kind {
        case .runtime: return "terminal"
        case .headlessBrowser: return "globe"
        case .languageServer: return "text.cursor"
        case .buildDaemon: return "hammer"
        case .emulator: return "candybarphone"
        case .androidBridge: return "cable.connector"
        }
    }
}
