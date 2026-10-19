import SwiftUI

/// How strongly the accent colours the app.
enum ThemeStyle: String, CaseIterable, Identifiable {
    /// The whole window is an accent gradient with glass cards.
    case vivid
    /// A light wash of the accent over the standard background.
    case subtle
    /// Standard macOS look.
    case classic

    var id: String { rawValue }

    var label: LocalizedStringKey {
        switch self {
        case .vivid: return "Vivid"
        case .subtle: return "Subtle"
        case .classic: return "Classic"
        }
    }

    var detail: LocalizedStringKey {
        switch self {
        case .vivid: return "The whole window takes on your colour."
        case .subtle: return "A soft wash of colour."
        case .classic: return "The standard macOS look."
        }
    }

    static var current: ThemeStyle {
        ThemeStyle(rawValue: UserDefaults.standard.string(forKey: PrefKey.themeStyle) ?? "") ?? .vivid
    }
}

/// Resolved colours for the current accent, style and light/dark mode.
struct Theme {
    var style: ThemeStyle = .classic
    var accent: Accent = .ocean
    var dark = true

    var isColored: Bool { style != .classic }
    var isVivid: Bool { style == .vivid }

    var accentColor: Color { accent.color }
    var deepColor: Color { accent.deepColor }

    /// Card fill on top of the background.
    var cardFill: AnyShapeStyle {
        switch style {
        case .vivid: return AnyShapeStyle(Color.white.opacity(dark ? 0.075 : 0.62))
        case .subtle: return AnyShapeStyle(Color.primary.opacity(dark ? 0.06 : 0.035))
        case .classic: return AnyShapeStyle(.background.secondary)
        }
    }

    var cardStroke: Color {
        switch style {
        case .vivid: return Color.white.opacity(dark ? 0.13 : 0.85)
        case .subtle: return accent.color.opacity(0.18)
        case .classic: return Color(nsColor: .separatorColor).opacity(0.5)
        }
    }

    /// Bottom bars (selection totals).
    var barFill: AnyShapeStyle {
        switch style {
        case .vivid: return AnyShapeStyle(Color.black.opacity(dark ? 0.22 : 0.05))
        case .subtle, .classic: return AnyShapeStyle(.bar)
        }
    }

    /// Solid sidebar text colours. Vivid backgrounds need them: the sidebar's vibrant text blends into the gradient.
    var sidebarText: Color? {
        isVivid ? (dark ? .white : Color.black.opacity(0.88)) : nil
    }

    var sidebarSecondaryText: Color? {
        isVivid ? (dark ? Color.white.opacity(0.78) : Color.black.opacity(0.62)) : nil
    }

    /// The sidebar sits a shade apart from the content.
    var sidebarOverlay: Color {
        switch style {
        case .vivid: return dark ? Color.black.opacity(0.22) : Color.white.opacity(0.38)
        case .subtle: return accent.color.opacity(dark ? 0.08 : 0.05)
        case .classic: return .clear
        }
    }
}

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = Theme()
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

/// The full-window background for the current theme.
struct ThemeBackground: View {
    @Environment(\.theme) private var theme

    var body: some View {
        switch theme.style {
        case .classic:
            Color(nsColor: .windowBackgroundColor)
        case .subtle:
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                LinearGradient(colors: [theme.accentColor.opacity(theme.dark ? 0.20 : 0.12), theme.accentColor.opacity(0.02)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        case .vivid:
            ZStack {
                LinearGradient(colors: theme.dark
                               ? [theme.accentColor.mix(with: .black, by: 0.30), theme.deepColor.mix(with: .black, by: 0.62)]
                               : [theme.accentColor.mix(with: .white, by: 0.70), theme.accentColor.mix(with: .white, by: 0.88)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(colors: [theme.accentColor.opacity(theme.dark ? 0.55 : 0.30), .clear],
                               center: .topTrailing, startRadius: 0, endRadius: 900)
                RadialGradient(colors: [theme.deepColor.opacity(theme.dark ? 0.55 : 0.18), .clear],
                               center: .bottomLeading, startRadius: 0, endRadius: 700)
            }
        }
    }
}

/// Applies the theme to a window's root view: background, transparent toolbar and list backgrounds, tint.
struct ThemedRoot: ViewModifier {
    @AppStorage(PrefKey.themeStyle) private var styleRaw = ThemeStyle.vivid.rawValue
    @AppStorage(PrefKey.accent) private var accentRaw = Accent.ocean.rawValue
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let theme = Theme(style: ThemeStyle(rawValue: styleRaw) ?? .vivid,
                          accent: Accent(rawValue: accentRaw) ?? .ocean,
                          dark: colorScheme == .dark)
        content
            .environment(\.theme, theme)
            .tint(theme.accentColor.mix(with: .white, by: theme.isVivid && theme.dark ? 0.15 : 0))
            .scrollContentBackground(theme.isColored ? .hidden : .automatic)
            .background { ThemeBackground().environment(\.theme, theme).ignoresSafeArea() }
            .toolbarBackground(theme.isColored ? .hidden : .automatic, for: .windowToolbar)
    }
}

extension View {
    func themedRoot() -> some View { modifier(ThemedRoot()) }
}

// MARK: - Buttons

/// The app's primary action: a bold gradient capsule.
struct PillButtonStyle: ButtonStyle {
    enum Kind { case accent, destructive }
    var kind: Kind = .accent
    var large = false
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let colors: [Color] = kind == .destructive
            ? [Color(red: 1.0, green: 0.36, blue: 0.36), Color(red: 0.80, green: 0.12, blue: 0.20)]
            : [theme.accentColor.mix(with: .white, by: 0.12), theme.deepColor]
        configuration.label
            .lineLimit(1)
            .fixedSize()
            .font((large ? Font.body : Font.callout).weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, large ? 22 : 14)
            .padding(.vertical, large ? 10 : 6)
            .background(Capsule().fill(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.22), lineWidth: 1))
            .shadow(color: (kind == .destructive ? Color.red : theme.accentColor).opacity(isEnabled ? 0.35 : 0), radius: 10, y: 4)
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

/// A secondary glass capsule.
struct GlassButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .lineLimit(1)
            .fixedSize()
            .font(.callout.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(theme.isVivid ? AnyShapeStyle(Color.white.opacity(theme.dark ? 0.12 : 0.6)) : AnyShapeStyle(.quaternary)))
            .overlay(Capsule().strokeBorder(theme.isVivid ? Color.white.opacity(theme.dark ? 0.16 : 0.9) : Color.clear))
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
            .contentShape(Capsule())
    }
}

extension ButtonStyle where Self == PillButtonStyle {
    static var pill: PillButtonStyle { PillButtonStyle() }
    static var pillLarge: PillButtonStyle { PillButtonStyle(large: true) }
    static var pillDestructive: PillButtonStyle { PillButtonStyle(kind: .destructive) }
}

extension ButtonStyle where Self == GlassButtonStyle {
    static var softGlass: GlassButtonStyle { GlassButtonStyle() }
}
