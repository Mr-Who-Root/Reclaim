import SwiftUI

struct MaintenanceView: View {
    @Bindable private var model = AppModel.shared.maintenance
    @State private var confirming: MaintenanceModel.Action?
    @State private var confirmingRepo: GitRepoStatus?

    var body: some View {
        VStack(spacing: 0) {
            ToolHeader(route: .maintenance, subtitle: subtitle) {
                if model.phase.isDone {
                    Button { Task { await model.scan() } } label: { Label("Scan Again", systemImage: "arrow.clockwise") }
                        .disabled(model.running != nil)
                }
            }
            content
        }
        .alert(alertTitle, isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil; confirmingRepo = nil } })) {
            Button("Run", role: .destructive) {
                let action = confirming, repo = confirmingRepo
                Task {
                    switch action {
                    case .brewCleanup: await model.runBrewCleanup()
                    case .brewAutoremove: await model.runBrewAutoremove()
                    case .gc: if let repo { await model.gc(repo) }
                    case .gcAll: await model.gcAll()
                    case nil: break
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
    }

    private var subtitle: String {
        guard model.phase.isDone else { return Route.maintenance.tagline }
        return String(localized: "Up to \(Fmt.bytes(model.brewBytes + model.brewUnusedBytes + model.gitBytes)) · scanned \(Fmt.relative(model.phase.lastScan))")
    }

    private var alertTitle: String {
        switch confirming {
        case .brewCleanup: return String(localized: "Run brew cleanup?")
        case .brewAutoremove: return String(localized: "Run brew autoremove?")
        case .gc: return String(localized: "Pack \(confirmingRepo?.name ?? "")?")
        case .gcAll: return String(localized: "Pack \(Fmt.count(model.repos.filter { !$0.busy }.count, "repository", "repositories"))?")
        case nil: return ""
        }
    }

    private var alertMessage: String {
        switch confirming {
        case .brewCleanup:
            return String(localized: "Reclaim will run:\nbrew cleanup\n\nHomebrew deletes old versions and old downloads itself; they don't go to the Trash. The versions you use stay installed.")
        case .brewAutoremove:
            return String(localized: "Reclaim will run:\nbrew autoremove\n\nHomebrew uninstalls dependencies nothing you installed needs any more. Install one again with brew install.")
        case .gc, .gcAll:
            return String(localized: "Reclaim will run:\ngit gc\n\ngit packs loose objects into compressed files and drops unreachable ones older than two weeks. Your commits, branches and stashes don't change.")
        case nil:
            return ""
        }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .idle, .failed:
            ToolIntro(route: .maintenance,
                      title: "Let Homebrew and git tidy up",
                      message: "Homebrew keeps old versions of everything you upgrade, and busy git repositories collect loose objects. Reclaim asks each tool what it would clean and runs the tool's own command when you confirm.",
                      bullets: ["Uses Homebrew's own dry run to show what would go",
                                "git gc never changes your commits, branches or stashes",
                                "Skips repositories another app is using"],
                      buttonTitle: AccessCenter.shared.homeGranted ? "Scan" : "Grant Access & Scan",
                      action: { AccessCenter.shared.ensureAccess { Task { await model.scan() } } })
        case .scanning(let message):
            ScanningPanel(title: "Checking Homebrew and git", message: message, onCancel: { model.cancelScan() })
        case .done:
            if model.brewItems.isEmpty && model.brewUnused.isEmpty && model.repos.isEmpty {
                AllClearView(title: "Nothing to tidy",
                             message: allClearMessage,
                             action: { Task { await model.scan() } })
            } else {
                ScrollView {
                    VStack(spacing: 14) {
                        if !model.brewItems.isEmpty { brewCard }
                        if !model.brewUnused.isEmpty { unusedCard }
                        if !model.repos.isEmpty { gitCard }
                        if model.healthyRepoCount > 0 {
                            Label("\(Fmt.count(model.healthyRepoCount, "other repository", "other repositories")) in your code folders don't need packing.",
                                  systemImage: "checkmark.circle")
                                .font(.caption).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(20)
                }
            }
        }
    }

    private var allClearMessage: String {
        var parts: [String] = []
        parts.append(model.brewInstalled ? String(localized: "Homebrew has nothing to clean up.") : String(localized: "Homebrew isn't installed."))
        parts.append(String(localized: "\(Fmt.count(model.healthyRepoCount, "repository", "repositories")) checked, none need packing."))
        return parts.joined(separator: " ")
    }

    private var brewCard: some View {
        ResultGroupCard {
            ResultGroupHeader(icon: "mug", title: String(localized: "Homebrew cleanup"),
                              subtitle: String(localized: "Old versions of formulae you've upgraded, Homebrew's own old files and downloads older than 120 days."),
                              total: Fmt.bytes(model.brewBytes))
        } content: {
            itemRows(model.brewItems)
            commandRow("brew cleanup", isRunning: model.running == .brewCleanup) { confirming = .brewCleanup }
        }
    }

    private var unusedCard: some View {
        ResultGroupCard {
            ResultGroupHeader(icon: "shippingbox", title: String(localized: "Unused dependencies"),
                              subtitle: String(localized: "Formulae installed only as dependencies of things you've since removed."),
                              total: Fmt.bytes(model.brewUnusedBytes))
        } content: {
            itemRows(model.brewUnused)
            commandRow("brew autoremove", isRunning: model.running == .brewAutoremove) { confirming = .brewAutoremove }
        }
    }

    private var gitCard: some View {
        ResultGroupCard {
            HStack(alignment: .firstTextBaseline) {
                ResultGroupHeader(icon: "arrow.triangle.branch", title: String(localized: "Git repositories"),
                                  subtitle: String(localized: "Repositories with many loose objects or stale worktree entries. Packing usually shrinks loose objects to a fraction of their size."),
                                  total: Fmt.bytes(model.gitBytes))
            }
        } content: {
            ForEach(model.repos) { repo in
                RowDivider(inset: 34)
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(repo.name).lineLimit(1)
                            if repo.busy { Badge(text: "In use", color: .orange) }
                        }
                        Text(details(for: repo)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 12)
                    Text(Fmt.bytes(repo.estimate)).font(.callout).monospacedDigit().foregroundStyle(.secondary)
                    if model.running == .gc(repo.id) || model.running == .gcAll {
                        ProgressView().controlSize(.small).frame(width: 60)
                    } else {
                        Button("Pack…") { confirmingRepo = repo; confirming = .gc(repo.id) }
                            .buttonStyle(.softGlass)
                            .disabled(repo.busy || model.running != nil)
                    }
                }
                .padding(.leading, 34)
                .contextMenu { Button("Show in Finder") { FS.reveal([repo.url]) } }
            }
            if model.repos.count > 1 {
                commandRow("git gc", isRunning: model.running == .gcAll, title: String(localized: "Pack All…")) { confirming = .gcAll }
            }
        }
    }

    private func details(for repo: GitRepoStatus) -> String {
        var parts = [FS.abbreviate(repo.url.path)]
        if repo.looseBytes > 0 { parts.append(String(localized: "\(Fmt.bytes(repo.looseBytes)) loose")) }
        if repo.garbageBytes > 0 { parts.append(String(localized: "\(Fmt.bytes(repo.garbageBytes)) garbage")) }
        if repo.packCount >= 25 { parts.append(Fmt.count(repo.packCount, "pack file")) }
        if repo.prunableWorktrees > 0 { parts.append(Fmt.count(repo.prunableWorktrees, "stale worktree")) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private func itemRows(_ items: [BrewItem]) -> some View {
        ForEach(items.prefix(6)) { item in
            RowDivider(inset: 34)
            HStack {
                Text(item.name).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 12)
                Text(Fmt.bytes(item.bytes)).font(.callout).monospacedDigit().foregroundStyle(.secondary)
            }
            .padding(.leading, 34)
            .help(item.url.path)
        }
        if items.count > 6 {
            RowDivider(inset: 34)
            Text("and \(Fmt.count(items.count - 6, "more item"))").font(.caption).foregroundStyle(.secondary).padding(.leading, 34)
        }
    }

    private func commandRow(_ command: String, isRunning: Bool, title: String? = nil, action: @escaping () -> Void) -> some View {
        VStack(spacing: 10) {
            RowDivider(inset: 34)
            HStack(spacing: 10) {
                Text(command).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))
                Spacer()
                if isRunning {
                    ProgressView().controlSize(.small)
                    Text("Running…").font(.callout).foregroundStyle(.secondary)
                } else {
                    Button(title ?? String(localized: "Run…"), action: action)
                        .buttonStyle(.softGlass)
                        .disabled(model.running != nil)
                }
            }
            .padding(.leading, 34)
        }
    }
}
