import SwiftUI
import QuickLook

// MARK: - Headers

/// The rounded, coloured tool glyph used in the sidebar, headers and cards.
struct RouteIcon: View {
    let route: Route
    var side: CGFloat = 36
    var body: some View {
        Image(systemName: route.icon)
            .font(.system(size: side * 0.46, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: side, height: side)
            .background(RoundedRectangle(cornerRadius: side * 0.27, style: .continuous).fill(route.color.gradient))
            .overlay(RoundedRectangle(cornerRadius: side * 0.27, style: .continuous).strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
            .shadow(color: route.color.opacity(side > 30 ? 0.35 : 0), radius: side * 0.18, y: side * 0.06)
            .accessibilityHidden(true)
    }
}

/// Title row at the top of every tool.
struct ToolHeader<Trailing: View>: View {
    let route: Route
    var subtitle: String? = nil
    @ViewBuilder var trailing: () -> Trailing

    init(route: Route, subtitle: String? = nil, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.route = route
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            RouteIcon(route: route, side: 42)
            VStack(alignment: .leading, spacing: 2) {
                Text(route.title).font(.system(.title2, design: .rounded).weight(.bold))
                Text(subtitle ?? route.tagline).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 12)
            trailing()
                .buttonStyle(.softGlass)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }
}

// MARK: - States

/// What a tool shows before its first scan.
struct ToolIntro<Accessory: View>: View {
    let route: Route
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    var bullets: [LocalizedStringKey] = []
    var buttonTitle: LocalizedStringKey = "Scan"
    let action: () -> Void
    @ViewBuilder var accessory: () -> Accessory

    init(route: Route, title: LocalizedStringKey, message: LocalizedStringKey, bullets: [LocalizedStringKey] = [], buttonTitle: LocalizedStringKey = "Scan",
         action: @escaping () -> Void, @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() }) {
        self.route = route
        self.title = title
        self.message = message
        self.bullets = bullets
        self.buttonTitle = buttonTitle
        self.action = action
        self.accessory = accessory
    }

    var body: some View {
        VStack(spacing: 18) {
            RouteIcon(route: route, side: 72)
            Text(title).font(.system(.title, design: .rounded).weight(.bold)).multilineTextAlignment(.center)
            Text(message).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 520)
            if !bullets.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(bullets.indices, id: \.self) { i in
                        let b = bullets[i]
                        Label(b, systemImage: "checkmark.circle.fill").foregroundStyle(.secondary)
                            .symbolRenderingMode(.hierarchical)
                    }
                }
                .font(.callout)
            }
            accessory()
            Button(action: action) {
                Label(buttonTitle, systemImage: "magnifyingglass")
            }
            .buttonStyle(.pillLarge)
            .keyboardShortcut(.defaultAction)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Shown while a scan is running.
struct ScanningPanel: View {
    let title: LocalizedStringKey
    let message: String?
    var onCancel: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text(title).font(.title3.weight(.semibold))
            if let message {
                Text(message).font(.callout).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle).multilineTextAlignment(.center).frame(maxWidth: 520)
                    .monospacedDigit()
            }
            Text("Nothing is being changed. Reclaim is only looking.").font(.caption).foregroundStyle(.tertiary)
            if let onCancel {
                Button("Stop Scan", action: onCancel).controlSize(.regular)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A finished scan with nothing to show.
struct AllClearView: View {
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    var actionTitle: LocalizedStringKey = "Scan Again"
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 54))
                .foregroundStyle(.green.gradient)
            Text(title).font(.title2.weight(.semibold))
            Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 480)
            if let action {
                Button(actionTitle, action: action).buttonStyle(.softGlass)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Selection

/// Bottom bar with the selection total and the Move to Trash button. Confirms before acting.
struct SelectionBar<Leading: View>: View {
    let count: Int
    let bytes: Int64
    var actionTitle: LocalizedStringKey = "Move to Trash"
    var isWorking: Bool = false
    let action: () -> Void
    @ViewBuilder var leading: () -> Leading
    @State private var confirming = false
    @Environment(\.theme) private var theme

    init(count: Int, bytes: Int64, actionTitle: LocalizedStringKey = "Move to Trash", isWorking: Bool = false,
         action: @escaping () -> Void, @ViewBuilder leading: @escaping () -> Leading = { EmptyView() }) {
        self.count = count
        self.bytes = bytes
        self.actionTitle = actionTitle
        self.isWorking = isWorking
        self.action = action
        self.leading = leading
    }

    var body: some View {
        HStack(spacing: 12) {
            leading()
            Spacer()
            if count == 0 {
                Text("Nothing selected").foregroundStyle(.secondary)
            } else {
                Text("\(Fmt.count(count, "item")) selected · \(Text(Fmt.bytes(bytes)).fontWeight(.semibold).foregroundStyle(.primary))")
                    .foregroundStyle(.secondary)
            }
            Button(role: .destructive) { confirming = true } label: {
                if isWorking { ProgressView().controlSize(.small) } else { Label(actionTitle, systemImage: "trash") }
            }
            .buttonStyle(.pillDestructive)
            .disabled(count == 0 || isWorking)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(theme.barFill)
        .overlay(alignment: .top) { Divider() }
        .confirmationDialog(Text("Move \(Fmt.count(count, "item")) (\(Fmt.bytes(bytes))) to the Trash?"),
                            isPresented: $confirming) {
            Button(actionTitle, role: .destructive, action: action)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Everything stays recoverable in the Trash until you empty it. You can also undo right after.")
        }
    }
}

/// A selectable file row with icon, location, date and size.
struct FileRow: View {
    let entry: FileEntry
    let isSelected: Bool
    var detail: String? = nil
    var badge: String? = nil
    var badgeColor: Color = .secondary
    var showsDate = true
    let toggle: () -> Void
    var onQuickLook: ((URL) -> Void)? = nil

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { isSelected }, set: { _ in toggle() }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityLabel(isSelected ? "Selected for removal" : "Not selected for removal")
            FileIconView(url: entry.url, side: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.name).lineLimit(1).truncationMode(.middle)
                    if let badge { Badge(text: badge, color: badgeColor) }
                }
                Text(detail ?? entry.parentDisplayPath)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if showsDate {
                Text(Fmt.date(entry.modified)).font(.caption).foregroundStyle(.secondary)
                    .frame(width: 92, alignment: .trailing)
            }
            // A folder measuring zero bytes is one macOS wouldn't let us read, not an empty one.
            Text(entry.size == 0 && entry.isDirectory ? "—" : Fmt.bytes(entry.size)).monospacedDigit().fontWeight(.medium)
                .frame(width: 84, alignment: .trailing)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onQuickLook?(entry.url) }
        .contextMenu {
            Button(isSelected ? "Deselect" : "Select", action: toggle)
            Divider()
            if let onQuickLook { Button("Quick Look") { onQuickLook(entry.url) } }
            Button("Reveal in Finder") { FS.reveal([entry.url]) }
            Button("Open") { FS.open(entry.url) }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.path, forType: .string)
            }
            Divider()
            Button("Never Suggest This") { Exclusions.shared.add(entry.url) }
        }
    }
}

// MARK: - Small pieces

struct Badge: View {
    let text: String
    var color: Color = .secondary
    var body: some View {
        Text(Fmt.loc(text))
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(Capsule().fill(color.opacity(0.14)))
    }
}

struct StatTile: View {
    let title: LocalizedStringKey
    let value: String
    var caption: String? = nil
    var tint: Color? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.title2, design: .rounded).weight(.bold)).monospacedDigit()
                .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.tint))
            if let caption { Text(caption).font(.caption2).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

struct CardModifier: ViewModifier {
    var padding: CGFloat = 14
    @Environment(\.theme) private var theme
    func body(content: Content) -> some View {
        let radius: CGFloat = theme.isVivid ? 16 : 12
        content
            .padding(padding)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(theme.cardFill))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(theme.cardStroke))
            .shadow(color: .black.opacity(theme.isVivid && !theme.dark ? 0.06 : 0), radius: 8, y: 2)
    }
}

extension View {
    func card(padding: CGFloat = 14) -> some View { modifier(CardModifier(padding: padding)) }
}

/// A row of selectable filter chips with optional counts.
struct ChipPicker<T: Hashable>: View {
    @Environment(\.theme) private var theme
    @Binding var selection: T
    let options: [T]
    let label: (T) -> String
    var count: ((T) -> Int?)? = nil

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(options, id: \.self) { option in
                    let selected = option == selection
                    Button {
                        selection = option
                    } label: {
                        HStack(spacing: 4) {
                            Text(Fmt.loc(label(option)))
                            if let n = count?(option) {
                                Text("\(n)").foregroundStyle(selected ? .white.opacity(0.85) : .secondary).monospacedDigit()
                            }
                        }
                        .font(.callout.weight(selected ? .semibold : .regular))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .foregroundStyle(selected ? .white : .primary)
                        .background(Capsule().fill(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(theme.isVivid ? Color.white.opacity(theme.dark ? 0.10 : 0.55) : Color.secondary.opacity(0.12))))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(.horizontal, 20)
        }
    }
}

/// Lets a tool scan its default folders, the Home folder, a saved folder, or a newly chosen one.
struct ScopeMenu: View {
    @Binding var scope: ScanScope
    let defaultsLabel: String
    var folders = FolderStore.shared

    var body: some View {
        Menu {
            Button(defaultsLabel) { scope = .defaults }
            Button("Home folder") { scope = .home }
            if !folders.folders.isEmpty {
                Divider()
                ForEach(folders.folders, id: \.path) { url in
                    Button(FS.abbreviate(url.path)) { scope = .folder(url) }
                }
            }
            Divider()
            Button("Choose Folder…") {
                if let url = folders.chooseFolder() { scope = .folder(url) }
            }
        } label: {
            Label(scope.label(defaultsLabel: defaultsLabel), systemImage: "folder")
        }
        .fixedSize()
        .help("Changes where this tool scans")
    }
}

/// Explains that some areas need Full Disk Access, with a button to open the right settings pane.
struct FullDiskAccessBanner: View {
    let reason: LocalizedStringKey
    @State private var granted = FS.hasFullDiskAccess()

    var body: some View {
        if !granted {
            HStack(spacing: 12) {
                Image(systemName: "lock.shield").font(.title2).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Full Disk Access unlocks more").font(.callout.weight(.semibold))
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Open Settings") { FS.openFullDiskAccessSettings() }
                Button("Check Again") { granted = FS.hasFullDiskAccess() }
            }
            .card(padding: 12)
            .padding(.horizontal, 20)
        }
    }
}

/// A capsule progress bar.
struct UsageBar: View {
    @Environment(\.theme) private var theme
    let fraction: Double
    var tint: Color? = nil
    var height: CGFloat = 10
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(theme.isVivid ? AnyShapeStyle(Color.white.opacity(theme.dark ? 0.14 : 0.6)) : AnyShapeStyle(.quaternary))
                Capsule().fill(tint.map { AnyShapeStyle($0.gradient) } ?? AnyShapeStyle(.tint)).frame(width: max(height, geo.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityValue(Fmt.percent(fraction))
    }
}

/// Floating confirmation after moving items to the Trash, with Undo.
struct ToastView: View {
    let toast: Toast
    let onUndo: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: toast.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(toast.isError ? .orange : .green)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(toast.message).font(.callout.weight(.semibold))
                if let detail = toast.detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
            }
            if !toast.undoIDs.isEmpty {
                Button("Undo", action: onUndo).buttonStyle(.bordered)
            }
            Button(action: onDismiss) { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        .padding(.bottom, 64)
        .frame(maxWidth: 560)
    }
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    var message: String
    var detail: String? = nil
    var undoIDs: [UUID] = []
    var isError = false
}

/// A labelled section title used inside tool content.
struct SectionTitle: View {
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline)
            if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension AllClearView {
    /// For messages built at runtime (already localized or verbatim, e.g. an error description).
    @_disfavoredOverload
    init(title: LocalizedStringKey, message: String, actionTitle: LocalizedStringKey = "Scan Again", action: (() -> Void)? = nil) {
        self.init(title: title, message: "\(message)", actionTitle: actionTitle, action: action)
    }
}

// MARK: - Boxed result groups

/// One boxed group of results: a header (icon, title, total) and its rows separated by hairlines.
struct ResultGroupCard<Header: View, Content: View>: View {
    @ViewBuilder var header: () -> Header
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header()
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 16)
    }
}

/// The standard header row of a result group.
struct ResultGroupHeader<Leading: View>: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    var total: String? = nil
    @ViewBuilder var leading: () -> Leading

    init(icon: String, title: String, subtitle: String? = nil, total: String? = nil,
         @ViewBuilder leading: @escaping () -> Leading = { EmptyView() }) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.total = total
        self.leading = leading
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            leading()
            Image(systemName: icon).font(.title3).foregroundStyle(.tint).frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(.title3, design: .rounded).weight(.semibold))
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            if let total {
                Text(total).font(.headline).monospacedDigit()
            }
        }
    }
}

/// A thin separator between rows inside a result card.
struct RowDivider: View {
    var inset: CGFloat = 34
    var body: some View { Divider().opacity(0.45).padding(.leading, inset) }
}
