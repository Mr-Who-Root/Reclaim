import SwiftUI

struct SecurityView: View {
    private var model: SecurityModel { AppModel.shared.security }

    var body: some View {
        VStack(spacing: 0) {
            ToolHeader(route: .security, subtitle: headerSubtitle) {
                if model.phase.isDone {
                    HStack(spacing: 8) {
                        deepVerifyButton
                        Button { Task { await model.scan() } } label: {
                            Label("Check Again", systemImage: "arrow.clockwise")
                        }
                    }
                }
            }
            Divider()
            content
        }
    }

    private var headerSubtitle: String {
        if let date = model.phase.lastScan { return "Last checked \(Fmt.relative(date)) · read-only, nothing is changed" }
        return Route.security.tagline
    }

    @ViewBuilder private var deepVerifyButton: some View {
        if model.deepPhase.isRunning {
            Button("Stop Deep Verify") { model.cancelDeepVerify() }
        } else {
            Button { model.startDeepVerify() } label: {
                Label("Deep Verify", systemImage: "checkmark.shield")
            }
            .help("Checks each app's full contents against its signature. Slower, and nothing is changed.")
        }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .idle, .failed:
            SecurityIntro { Task { await model.scan() } }
        case .scanning(let message):
            ScanningPanel(title: "Reading signatures", message: message, onCancel: { model.cancelScan() })
        case .done:
            SecurityResults(model: model)
        }
    }
}

// MARK: - Intro

private struct SecurityIntro: View {
    let start: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                ToolIntro(route: .security,
                          title: "See who made what runs on your Mac",
                          message: "Security Check reads the signature macOS checks before it runs anything, looks at what starts by itself, and shows where your downloads came from. It only reads — nothing is moved, changed or removed.",
                          buttonTitle: "Run Security Check",
                          action: start)
                    .frame(minHeight: 380)
                HStack(alignment: .top, spacing: 14) {
                    SecurityCapabilityCard(title: "What it can tell you", icon: "checkmark.circle.fill", tint: .green, lines: [
                        "Who signed a program, and whether Apple notarised it",
                        "Whether code still matches its own signature",
                        "Which login items and background services exist, and what they launch",
                        "Which app downloaded a file, when, and from where",
                    ])
                    SecurityCapabilityCard(title: "What it can't do", icon: "xmark.circle.fill", tint: .secondary, lines: [
                        "Tell you whether a file is malware — Reclaim is not antivirus software and has no malware database",
                        "Anything requiring the internet — it never connects",
                        "Remove or quarantine anything",
                    ])
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 28)
            }
        }
    }
}

private struct SecurityCapabilityCard: View {
    let title: String
    let icon: String
    let tint: Color
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            ForEach(lines, id: \.self) { line in
                Label {
                    Text(line).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: icon).foregroundStyle(tint)
                }
                .font(.callout)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

// MARK: - Results

private enum SecuritySection: String, CaseIterable, Identifiable {
    case apps = "Apps"
    case startup = "What Starts by Itself"
    case origins = "Where Things Came From"
    var id: String { rawValue }
}

private struct SecurityResults: View {
    let model: SecurityModel
    @State private var section: SecuritySection = .apps

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    summary
                    if case .running(let done, let total, let current) = model.deepPhase {
                        DeepVerifyProgress(done: done, total: total, current: current)
                    }
                    Picker("Section", selection: $section) {
                        ForEach(SecuritySection.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    switch section {
                    case .apps: SecurityAppsSection(model: model)
                    case .startup: SecurityStartupSection(items: model.launchItems)
                    case .origins: SecurityOriginsSection(origins: model.origins)
                    }

                    Text("Reclaim is not antivirus software. It has no malware database and never connects to the internet, so it cannot tell you whether a file is malicious. It reads signatures and records macOS already keeps.")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.top, 8)
                }
                .padding(20)
            }
        }
    }

    @ViewBuilder private var summary: some View {
        HStack(spacing: 12) {
            StatTile(title: "Apps checked", value: "\(model.apps.count)",
                     caption: model.deepVerifiedCount > 0 ? "\(model.deepVerifiedCount) deep-verified" : "Identity checked")
            StatTile(title: "Need attention", value: "\(model.attentionCount)",
                     caption: "Unsigned, altered or orphaned", tint: model.attentionCount > 0 ? .red : .green)
            StatTile(title: "Start by themselves", value: "\(model.launchItems.count)", caption: "Agents & daemons")
            StatTile(title: "Downloads with a record", value: "\(model.origins.filter(\.hasRecord).count)",
                     caption: "of \(model.origins.count) in Downloads")
        }

        if model.attentionCount == 0 {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.shield.fill").font(.title).foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Everything Reclaim could check is signed and recognised.").font(.callout.weight(.semibold))
                    Text("That is what a healthy Mac looks like. It does not mean the Mac has been scanned for malware.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .card(padding: 12)
        } else {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.shield.fill").font(.title).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(Fmt.count(model.attentionCount, "item")) worth a closer look").font(.callout.weight(.semibold))
                    Text("For your information — these aren't necessarily harmful. Check that you recognise each one.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .card(padding: 12)
        }
    }
}

private struct DeepVerifyProgress: View {
    let done: Int
    let total: Int
    let current: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Deep verifying \(current)…").font(.callout.weight(.medium)).lineLimit(1)
                Spacer()
                Text("\(done) of \(total)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            ProgressView(value: Double(done), total: Double(max(total, 1)))
            Text("Checking each app's contents against its signature. This is slower, and nothing is being changed.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .card(padding: 12)
    }
}

// MARK: Apps

private struct SecurityAppsSection: View {
    let model: SecurityModel
    @State private var filter: AppFilter = .all

    enum AppFilter: Hashable {
        case all, attention, info, status(SecuritySignatureStatus)
    }

    private var options: [AppFilter] {
        [.all, .attention, .info] + SecuritySignatureStatus.allCases.filter { model.count($0) > 0 }.map { .status($0) }
    }

    private func label(_ f: AppFilter) -> String {
        switch f {
        case .all: return "All"
        case .attention: return "Needs attention"
        case .info: return "For your information"
        case .status(let s): return s.title
        }
    }

    private func matches(_ app: SecurityAppItem, _ f: AppFilter) -> Bool {
        switch f {
        case .all: return true
        case .attention: return app.signature.status.severity == .attention
        case .info: return app.signature.status.severity == .info
        case .status(let s): return app.signature.status == s
        }
    }

    var body: some View {
        let shown = model.apps.filter { matches($0, filter) }
        let groups = Dictionary(grouping: shown, by: \.signature.status).sorted { $0.key > $1.key }
        VStack(alignment: .leading, spacing: 12) {
            ChipPicker(selection: $filter, options: options, label: label,
                       count: { f in model.apps.filter { matches($0, f) }.count })
                .padding(.horizontal, -20)

            if shown.isEmpty {
                Text("No apps match this filter.").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(30)
            }
            ForEach(groups, id: \.key) { status, apps in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: status.icon).foregroundStyle(status.color).font(.title3).frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(status.title) · \(apps.count)").font(.headline)
                            Text(status.explanation).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    VStack(spacing: 0) {
                        ForEach(apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) { app in
                            SecurityAppRow(app: app)
                            if app.id != apps.last?.id { Divider().padding(.leading, 46) }
                        }
                    }
                    .card(padding: 8)
                }
            }
        }
    }
}

private struct SecurityAppRow: View {
    let app: SecurityAppItem

    var body: some View {
        HStack(spacing: 10) {
            FileIconView(url: app.url, side: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(app.name).fontWeight(.medium).lineLimit(1)
                    if let v = app.version { Text(v).font(.caption).foregroundStyle(.secondary) }
                }
                Text(signerLine).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if let detail = app.signature.detail, app.signature.status == .invalid {
                    Text(detail).font(.caption).foregroundStyle(.red).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            if app.signature.deepVerified {
                Image(systemName: "checkmark.seal").foregroundStyle(.secondary)
                    .help(app.signature.verificationNote)
            }
            Badge(text: app.signature.status.title, color: app.signature.status.color)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .help(app.signature.verificationNote)
        .contextMenu {
            Button("Reveal in Finder") { FS.reveal([app.url]) }
            if let id = app.bundleID {
                Button("Copy Bundle Identifier") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(id, forType: .string)
                }
            }
        }
    }

    private var signerLine: String {
        var parts: [String] = []
        if let signer = app.signature.signer { parts.append("Signing certificate: \(signer)") }
        if let team = app.signature.teamID { parts.append("Team \(team)") }
        if parts.isEmpty { parts.append(FS.abbreviate(app.url.deletingLastPathComponent().path)) }
        return parts.joined(separator: " · ")
    }
}

// MARK: Startup items

private struct SecurityStartupSection: View {
    let items: [SecurityLaunchItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Login items and background services installed as launch agents or daemons, and the code they launch. Apps registered through System Settings › Login Items may not appear here.")
                .font(.caption).foregroundStyle(.secondary)
            if items.isEmpty {
                Text("No launch agents or daemons found.").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(30)
            }
            ForEach(SecurityLaunchItem.Scope.allCases, id: \.self) { scope in
                let scoped = items.filter { $0.scope == scope }
                if !scoped.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("\(scope.title) · \(scoped.count)").font(.headline)
                            Spacer()
                            Text(scope.folder).font(.caption).foregroundStyle(.secondary)
                        }
                        VStack(spacing: 0) {
                            ForEach(scoped) { item in
                                SecurityLaunchRow(item: item)
                                if item.id != scoped.last?.id { Divider().padding(.leading, 34) }
                            }
                        }
                        .card(padding: 8)
                    }
                }
            }
        }
    }
}

private struct SecurityLaunchRow: View {
    let item: SecurityLaunchItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.isOrphaned ? "link.badge.plus" : "gearshape.2")
                .foregroundStyle(item.needsAttention ? .orange : .secondary)
                .frame(width: 24)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.label).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                if let program = item.program {
                    Text(FS.abbreviate(program)).font(.caption.monospaced()).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                } else {
                    Text("No program path listed").font(.caption).foregroundStyle(.secondary)
                }
                if item.isOrphaned {
                    Text("The program it points at is not on this Mac. Usually left behind by an app that was removed.")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(item.whenText).font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            if let sig = item.signature {
                Badge(text: sig.status.title, color: sig.status.color)
                    .help(sig.signer.map { "Signing certificate: \($0)" } ?? sig.status.explanation)
            } else if item.isOrphaned {
                Badge(text: "Program missing", color: .orange)
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Reveal Plist in Finder") { FS.reveal([item.plistURL]) }
            if let target = item.target { Button("Reveal Program in Finder") { FS.reveal([target]) } }
            Button("Copy Label") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.label, forType: .string)
            }
        }
    }
}

// MARK: Download origins

private struct SecurityOriginsSection: View {
    let origins: [SecurityDownloadOrigin]
    @State private var showUntracked = true

    var body: some View {
        let shown = showUntracked ? origins : origins.filter(\.hasRecord)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("The download record macOS attaches to files from the internet: which app saved them, when, and the address they came from.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Toggle("Show files without a record", isOn: $showUntracked).toggleStyle(.switch).controlSize(.small)
            }
            if shown.isEmpty {
                Text(origins.isEmpty ? "Downloads is empty, or Reclaim couldn't read it." : "No files with a download record.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(30)
            } else {
                VStack(spacing: 0) {
                    ForEach(shown) { origin in
                        SecurityOriginRow(origin: origin)
                        if origin.id != shown.last?.id { Divider().padding(.leading, 46) }
                    }
                }
                .card(padding: 8)
            }
        }
    }
}

private struct SecurityOriginRow: View {
    let origin: SecurityDownloadOrigin

    var body: some View {
        HStack(spacing: 10) {
            FileIconView(url: origin.url, side: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(origin.name).lineLimit(1).truncationMode(.middle)
                Text(origin.summary).font(.caption).foregroundStyle(origin.hasRecord ? .secondary : .tertiary)
                    .lineLimit(2)
                if let source = origin.source {
                    Text(source.absoluteString).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            if origin.quarantined { Badge(text: "Quarantine record", color: .blue) }
            if origin.size > 0 {
                Text(Fmt.bytes(origin.size)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    .frame(width: 70, alignment: .trailing)
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Reveal in Finder") { FS.reveal([origin.url]) }
            if let source = origin.source {
                Button("Copy Source Address") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(source.absoluteString, forType: .string)
                }
            }
            if let referrer = origin.referrer {
                Button("Copy Referring Page") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(referrer.absoluteString, forType: .string)
                }
            }
        }
    }
}
