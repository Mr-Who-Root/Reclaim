import AppKit

/// Developer processes still running on their own: dev servers and headless browsers whose terminal closed,
/// build daemons, and dev servers you're running from a terminal. Read-only until you quit one.
@MainActor @Observable
final class DevProcessesModel {
    private(set) var phase: ScanPhase = .idle
    private(set) var groups: [DevProcessGroup] = []
    private(set) var quitting: Set<pid_t> = []
    /// Groups that ignored a normal quit and can be force quit.
    private(set) var stubborn: Set<pid_t> = []
    private var work: Task<Void, Never>?

    var leftBehind: [DevProcessGroup] { groups.filter { $0.status == .leftBehind } }
    var helpers: [DevProcessGroup] { groups.filter { $0.status == .helper } }
    var running: [DevProcessGroup] { groups.filter { $0.status == .running } }
    var leftBehindMemory: Int64 { leftBehind.reduce(0) { $0 + $1.memory } }

    /// Reads the process list. The first time shows progress; later refreshes update in place.
    func refresh() async {
        if case .scanning = phase { return }
        if groups.isEmpty, !phase.isDone { phase = .scanning(String(localized: "Looking at running processes…")) }
        let found = await offPool { DevProcessScanner.scan() }
        groups = found
        stubborn.formIntersection(Set(found.map(\.id)))
        phase = .done(.now)
    }

    /// Keeps the list current while a screen shows it.
    func startLiveUpdates() {
        work?.cancel()
        work = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func stopLiveUpdates() { work?.cancel(); work = nil }

    func quit(_ group: DevProcessGroup, force: Bool = false) async {
        guard !quitting.contains(group.id) else { return }
        quitting.insert(group.id)
        let survivors = await DevProcessScanner.quit(group, force: force)
        quitting.remove(group.id)
        if survivors.isEmpty {
            stubborn.remove(group.id)
            groups.removeAll { $0.id == group.id }
            AppModel.shared.showToast(Toast(message: String(localized: "Quit \(group.title)"),
                                            detail: String(localized: "Freed about \(Fmt.bytes(group.memory)) of memory.")))
        } else {
            stubborn.insert(group.id)
            AppModel.shared.showToast(Toast(message: String(localized: "\(group.title) is still running"),
                                            detail: String(localized: "It didn't respond to a normal quit. You can force quit it."), isError: true))
        }
        await refresh()
    }

    func quitAllLeftBehind() async {
        let targets = leftBehind
        var freed: Int64 = 0, failed = 0
        for g in targets {
            let survivors = await DevProcessScanner.quit(g, force: false)
            if survivors.isEmpty { freed += g.memory } else { failed += 1; stubborn.insert(g.id) }
        }
        let quitCount = targets.count - failed
        AppModel.shared.showToast(Toast(message: String(localized: "Quit \(Fmt.count(quitCount, "process group"))"),
                                        detail: failed > 0
                                            ? String(localized: "\(Fmt.count(failed, "process group")) didn't respond. You can force quit them.")
                                            : String(localized: "Freed about \(Fmt.bytes(freed)) of memory."),
                                        isError: failed > 0))
        await refresh()
    }

    func revealFolder(_ group: DevProcessGroup) {
        guard let cwd = group.root.cwd else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: cwd)])
    }

    func copyCommand(_ group: DevProcessGroup) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(group.commandLine, forType: .string)
    }
}
