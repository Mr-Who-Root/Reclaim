import SwiftUI

/// The five kinds of AI leftovers.
enum AIJunkCategory: String, CaseIterable, Identifiable, Sendable {
    case temp, agents, caches, models, generated

    var id: String { rawValue }

    var title: String {
        switch self {
        case .temp: return "Stale AI temp files"
        case .agents: return "Coding agent leftovers"
        case .caches: return "AI app caches & logs"
        case .models: return "Downloaded AI models"
        case .generated: return "AI-generated images"
        }
    }

    var icon: String {
        switch self {
        case .temp: return "clock.arrow.circlepath"
        case .agents: return "terminal"
        case .caches: return "internaldrive"
        case .models: return "cube.box"
        case .generated: return "wand.and.stars"
        }
    }

    var explanation: String {
        switch self {
        case .temp:
            return "Scratch folders, headless browser profiles and compile caches that AI tools and agents leave in the system temp folders. Only items nothing has touched recently and no running app has open are listed."
        case .agents:
            return "Old sessions, checkpoints, snapshots and worktrees from Claude Code, Codex, Gemini, Cursor and Aider. Histories you might still resume are marked Caution."
        case .caches:
            return "Browser-engine caches, logs and old bundled versions kept by AI apps. They rebuild on their own. Quit an app first if it has its cache open."
        case .models:
            return "Model weights from Hugging Face, Ollama, LM Studio and others. Often many gigabytes each — they download again the next time you use them, so they're never selected for you."
        case .generated:
            return "Images in Downloads, Desktop and Pictures that are named or tagged like exports from ChatGPT, DALL·E, Gemini, Midjourney, Firefly, Stable Diffusion and similar. Never selected for you."
        }
    }
}

enum AIJunkSafety: Sendable {
    case safe, caution
    var label: String { self == .safe ? "Safe" : "Caution" }
    var color: Color { self == .safe ? .green : .orange }
}

/// One path an item moves to the Trash.
struct AIJunkTarget: Hashable, Sendable {
    let url: URL
    let bytes: Int64
}

/// One reviewable AI leftover.
struct AIJunkItem: Identifiable, Hashable, Sendable {
    /// Primary path; also the selection id.
    let id: String
    let category: AIJunkCategory
    /// The tool that made it, e.g. "Claude Code", "Ollama", "Puppeteer".
    let source: String
    let title: String
    /// Why it's listed, in plain words.
    let detail: String
    let safety: AIJunkSafety
    /// What Finder shows for this item (a folder for grouped items).
    let url: URL
    /// What actually goes to the Trash.
    let targets: [AIJunkTarget]
    /// Newest modification inside it.
    let lastActivity: Date?
    let isDirectory: Bool
    /// Name of a running process that has something inside open.
    var inUseBy: String?

    var bytes: Int64 { targets.reduce(0) { $0 + $1.bytes } }
    var isSelectable: Bool { inUseBy == nil }
    /// True when moving `url` itself is the whole action (safe to hand to Guided Cleanup).
    var isSingleTarget: Bool { targets.count == 1 && targets[0].url.path == url.path }

    var entry: FileEntry {
        FileEntry(url: url, size: bytes, modified: lastActivity, created: nil, isDirectory: isDirectory)
    }
}
