import SwiftUI

/// Every screen in the sidebar. Also used by URLs (`reclaim://junk`), Spotlight and Shortcuts.
enum Route: String, CaseIterable, Identifiable, Codable, Hashable {
    case home, guided, junk, ai, downloads, duplicates, photos, large, map, apps, security, trash, settings

    var id: String { rawValue }

    enum Section: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case clean = "Clean Up"
        case explore = "Explore"
        case review = "Review"
        case app = "App"
        var id: String { rawValue }
        var title: String {
            switch self {
            case .overview: return String(localized: "Overview")
            case .clean: return String(localized: "Clean Up")
            case .explore: return String(localized: "Explore")
            case .review: return String(localized: "Review")
            case .app: return String(localized: "App")
            }
        }
    }

    var section: Section {
        switch self {
        case .home, .guided: return .overview
        case .junk, .ai, .downloads, .duplicates, .photos, .large, .apps: return .clean
        case .map, .security: return .explore
        case .trash: return .review
        case .settings: return .app
        }
    }

    var title: String {
        switch self {
        case .home: return String(localized: "Mac Overview")
        case .guided: return String(localized: "Guided Cleanup")
        case .junk: return String(localized: "Junk")
        case .ai: return String(localized: "AI Junk")
        case .downloads: return String(localized: "Downloads")
        case .duplicates: return String(localized: "Duplicates")
        case .photos: return String(localized: "Photo Clutter")
        case .large: return String(localized: "Large & Old Files")
        case .map: return String(localized: "Storage Map")
        case .apps: return String(localized: "Apps & Leftovers")
        case .security: return String(localized: "Security Check")
        case .trash: return String(localized: "Trash")
        case .settings: return String(localized: "Settings")
        }
    }

    var tagline: String {
        switch self {
        case .home: return String(localized: "Free space at a glance, and one scan across every tool")
        case .guided: return String(localized: "A reviewed, step-by-step clean you approve")
        case .junk: return String(localized: "Caches, logs & developer junk")
        case .ai: return String(localized: "Agent temp files, AI app caches & models")
        case .downloads: return String(localized: "Old installers, archives & stale downloads")
        case .duplicates: return String(localized: "Byte-for-byte identical files")
        case .photos: return String(localized: "Look-alikes, screenshots & blurry shots")
        case .large: return String(localized: "Big files you've forgotten")
        case .map: return String(localized: "See what's eating space")
        case .apps: return String(localized: "Uninstall apps and clear their leftovers")
        case .security: return String(localized: "Signatures, login items & download origins")
        case .trash: return String(localized: "Review & restore what was moved")
        case .settings: return String(localized: "Access, appearance, language, schedules and more")
        }
    }

    var icon: String {
        switch self {
        case .home: return "gauge.with.dots.needle.67percent"
        case .guided: return "checklist"
        case .junk: return "sparkles"
        case .ai: return "brain"
        case .downloads: return "arrow.down.circle"
        case .duplicates: return "doc.on.doc"
        case .photos: return "photo.on.rectangle.angled"
        case .large: return "archivebox"
        case .map: return "square.grid.2x2"
        case .apps: return "square.stack.3d.up"
        case .security: return "checkmark.shield"
        case .trash: return "trash"
        case .settings: return "gearshape"
        }
    }

    var color: Color {
        switch self {
        case .home: return .blue
        case .guided: return .indigo
        case .junk: return .orange
        case .ai: return .mint
        case .downloads: return .blue
        case .duplicates: return .purple
        case .photos: return .pink
        case .large: return .teal
        case .map: return .cyan
        case .apps: return .brown
        case .security: return .green
        case .trash: return .red
        case .settings: return .gray
        }
    }

    /// Tools that produce reclaimable results in Smart Scan.
    static let scanTools: [Route] = [.junk, .ai, .downloads, .duplicates, .photos, .large, .apps]
}
