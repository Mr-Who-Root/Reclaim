import Foundation
import CoreSpotlight
import UniformTypeIdentifiers

/// Spotlight entries for every tool, so ⌘ Space → "Duplicates" opens it.
@MainActor
enum SpotlightIndex {
    private static let domain = "com.govindsr.reclaim.tools"

    static func indexTools() {
        let items = Route.visible.map { route -> CSSearchableItem in
            let attributes = CSSearchableItemAttributeSet(contentType: .content)
            attributes.title = route == .home ? "Reclaim" : "\(route.title) — Reclaim"
            attributes.displayName = attributes.title
            attributes.contentDescription = route.tagline
            attributes.keywords = keywords(for: route)
            return CSSearchableItem(uniqueIdentifier: "tool.\(route.rawValue)", domainIdentifier: domain, attributeSet: attributes)
        }
        let index = CSSearchableIndex.default()
        index.deleteSearchableItems(withDomainIdentifiers: [domain]) { _ in
            index.indexSearchableItems(items) { _ in }
        }
    }

    static func handle(identifier: String) {
        guard identifier.hasPrefix("tool."), let route = Route(rawValue: String(identifier.dropFirst(5))) else { return }
        AppModel.shared.route = route
    }

    private static func keywords(for route: Route) -> [String] {
        var words = ["Reclaim", "clean", "cleanup", "disk space", "storage"]
        switch route {
        case .home: words += ["smart scan", "overview", "free space"]
        case .guided: words += ["guided", "plan", "review"]
        case .junk: words += ["cache", "caches", "logs", "xcode", "derived data", "npm", "homebrew"]
        case .ai: words += ["ai", "ai junk", "claude", "codex", "cursor", "ollama", "hugging face", "models", "temp files", "tmp"]
        case .dev: words += ["developer", "dev", "xcode", "android", "sdk", "disk usage"]
        case .toolchains: words += ["sdk", "toolchain", "ndk", "jdk", "java", "node", "nvm", "python", "pyenv", "rust", "rustup", "simulator runtime", "xcode"]
        case .maintenance: words += ["homebrew", "brew cleanup", "git gc", "git", "repository"]
        case .processes: words += ["processes", "dev server", "port", "headless chrome", "gradle daemon", "node", "kill"]
        case .docker: words += ["docker", "containers", "images", "volumes", "build cache", "prune"]
        case .downloads: words += ["installers", "dmg", "pkg", "zip", "archives"]
        case .duplicates: words += ["duplicate files", "copies", "identical"]
        case .photos: words += ["photos", "screenshots", "screen recordings", "blurry", "similar"]
        case .large: words += ["large files", "big files", "old files"]
        case .map: words += ["treemap", "disk usage", "folders"]
        case .leftovers: words += ["leftovers", "orphaned files", "app support", "remnants"]
        case .apps: words += ["uninstall", "uninstaller", "remove app", "applications"]
        case .security: words += ["security", "signature", "notarized", "login items", "launch agents"]
        case .trash: words += ["trash", "restore", "undo"]
        case .settings: words += ["settings", "preferences", "language", "appearance", "schedule"]
        }
        return words
    }
}
