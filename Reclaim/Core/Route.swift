import SwiftUI

/// Every screen in the sidebar. Also used by URLs (`reclaim://junk`), Spotlight and Shortcuts.
enum Route: String, CaseIterable, Identifiable, Codable, Hashable {
    case home, guided, junk, ai, downloads, duplicates, photos, large, map, apps, security, trash

    var id: String { rawValue }

    enum Section: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case clean = "Clean Up"
        case explore = "Explore"
        case review = "Review"
        var id: String { rawValue }
    }

    var section: Section {
        switch self {
        case .home, .guided: return .overview
        case .junk, .ai, .downloads, .duplicates, .photos, .large, .apps: return .clean
        case .map, .security: return .explore
        case .trash: return .review
        }
    }

    var title: String {
        switch self {
        case .home: return "Mac Overview"
        case .guided: return "Guided Cleanup"
        case .junk: return "Junk"
        case .ai: return "AI Junk"
        case .downloads: return "Downloads"
        case .duplicates: return "Duplicates"
        case .photos: return "Photo Clutter"
        case .large: return "Large & Old Files"
        case .map: return "Storage Map"
        case .apps: return "Apps & Leftovers"
        case .security: return "Security Check"
        case .trash: return "Trash"
        }
    }

    var tagline: String {
        switch self {
        case .home: return "Free space at a glance, and one scan across every tool"
        case .guided: return "A reviewed, step-by-step clean you approve"
        case .junk: return "Caches, logs & developer junk"
        case .ai: return "Agent temp files, AI app caches & models"
        case .downloads: return "Old installers, archives & stale downloads"
        case .duplicates: return "Byte-for-byte identical files"
        case .photos: return "Look-alikes, screenshots & blurry shots"
        case .large: return "Big files you've forgotten"
        case .map: return "See what's eating space"
        case .apps: return "Uninstall apps and clear their leftovers"
        case .security: return "Signatures, login items & download origins"
        case .trash: return "Review & restore what was moved"
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
        }
    }

    /// Tools that produce reclaimable results in Smart Scan.
    static let scanTools: [Route] = [.junk, .ai, .downloads, .duplicates, .photos, .large, .apps]
}
