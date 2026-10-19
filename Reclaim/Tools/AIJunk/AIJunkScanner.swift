import Foundation
import ImageIO

struct AIJunkScanResult: Sendable {
    var items: [AIJunkItem] = []
    /// Matching items left alone because something touched them recently.
    var skippedRecent = 0
    var skippedRecentBytes: Int64 = 0
    /// False if `lsof` couldn't run, so open files couldn't be ruled out.
    var openCheckAvailable = true
    /// Sources that exist but macOS wouldn't let Reclaim read.
    var blocked: [String] = []
}

/// Finds files left behind by AI tools: agent temp folders, session leftovers, app caches, models and generated images.
enum AIJunkScanner {
    static func run(idleDays: Int, reporter: ProgressReporter) -> AIJunkScanResult {
        var ctx = AIJunkContext(idle: TimeInterval(idleDays) * 86_400)
        reporter.report("Checking which files running apps have open…", force: true)
        ctx.open = AIOpenFiles.load()

        let probes: [(String, (inout AIJunkContext) -> Void)] = [
            ("Checking temp folders for agent scratch files…", scanTemp),
            ("Checking Claude Code…", scanClaudeCode),
            ("Checking Codex, Gemini, Cursor and Continue…", scanOtherAgents),
            ("Looking for agent worktrees and Aider caches in your projects…", scanProjects),
            ("Checking AI app caches and old versions…", scanAppCaches),
            ("Checking downloaded models…", scanModels),
            ("Looking for AI-generated images…", scanGenerated),
        ]
        for (message, probe) in probes {
            if Task.isCancelled { break }
            reporter.report(message, force: true)
            probe(&ctx)
        }

        let order = Dictionary(uniqueKeysWithValues: AIJunkCategory.allCases.enumerated().map { ($1, $0) })
        var result = AIJunkScanResult()
        result.items = ctx.items.sorted {
            order[$0.category]! != order[$1.category]! ? order[$0.category]! < order[$1.category]! : $0.bytes > $1.bytes
        }
        result.skippedRecent = ctx.skippedRecent
        result.skippedRecentBytes = ctx.skippedRecentBytes
        result.openCheckAvailable = ctx.open.available
        result.blocked = Array(Set(ctx.blocked)).sorted()
        return result
    }

    private static var home: URL { FS.home }
    private static func at(_ relative: String) -> URL { home.appendingPathComponent(relative) }
    private static func appSupport(_ app: String) -> URL { FS.library("Application Support").appendingPathComponent(app, isDirectory: true) }
    private static let thirtyDays: TimeInterval = 30 * 86_400

    // MARK: Temp folders

    private struct TempSource {
        let tokens: [String]
        let prefixOnly: Bool
        let source: String
        let title: String
        let detail: String
    }

    private static let tempSources: [TempSource] = [
        TempSource(tokens: ["puppeteer_dev_chrome_profile", "puppeteer"], prefixOnly: false, source: "Puppeteer", title: "Headless Chrome profile",
                   detail: "A throwaway browser profile left by browser automation, often driven by AI agents."),
        TempSource(tokens: ["playwright"], prefixOnly: false, source: "Playwright", title: "Browser automation data",
                   detail: "Temporary browser data left by Playwright automation, often driven by AI agents."),
        TempSource(tokens: ["com.anthropic.", "anthropic", "claude"], prefixOnly: false, source: "Claude", title: "Claude temp data",
                   detail: "Temporary files from Claude or Claude Code, such as update staging and scratch output."),
        TempSource(tokens: ["com.openai.", "openai", "chatgpt", "codex"], prefixOnly: false, source: "OpenAI", title: "ChatGPT / Codex temp data",
                   detail: "Temporary files from ChatGPT or the Codex agent."),
        TempSource(tokens: ["gemini", "antigravity"], prefixOnly: false, source: "Gemini", title: "Gemini temp data",
                   detail: "Temporary files from Gemini or the Antigravity agent."),
        TempSource(tokens: ["cursor"], prefixOnly: false, source: "Cursor", title: "Cursor temp data",
                   detail: "Temporary files from the Cursor editor or its agent terminals."),
        TempSource(tokens: ["windsurf", "codeium"], prefixOnly: false, source: "Windsurf", title: "Windsurf temp data",
                   detail: "Temporary files from Windsurf / Codeium."),
        TempSource(tokens: ["copilot"], prefixOnly: false, source: "GitHub Copilot", title: "Copilot temp data",
                   detail: "Temporary files from GitHub Copilot."),
        TempSource(tokens: ["ollama"], prefixOnly: false, source: "Ollama", title: "Ollama temp data",
                   detail: "Partial downloads and runner files from Ollama."),
        TempSource(tokens: ["lmstudio", "lm-studio", "lm_studio"], prefixOnly: false, source: "LM Studio", title: "LM Studio temp data",
                   detail: "Temporary files from LM Studio."),
        TempSource(tokens: ["gradio"], prefixOnly: false, source: "Gradio", title: "Gradio uploads & outputs",
                   detail: "Files uploaded to, or generated by, a local Gradio AI demo."),
        TempSource(tokens: ["torchinductor", "torch_extensions", "torch_compile", "triton"], prefixOnly: false, source: "PyTorch", title: "PyTorch compile cache",
                   detail: "Compiled kernels PyTorch rebuilds on demand."),
        TempSource(tokens: ["huggingface", "hf_", "hf-", "transformers"], prefixOnly: true, source: "Hugging Face", title: "Hugging Face temp data",
                   detail: "Temporary download or conversion files from Hugging Face libraries."),
        TempSource(tokens: ["aider"], prefixOnly: false, source: "Aider", title: "Aider temp data", detail: "Temporary files from the Aider coding agent."),
        TempSource(tokens: ["whisper"], prefixOnly: false, source: "Whisper", title: "Whisper temp audio", detail: "Temporary audio from Whisper transcription."),
        TempSource(tokens: ["comfyui", "comfy_"], prefixOnly: false, source: "ComfyUI", title: "ComfyUI temp output", detail: "Temporary previews and outputs from ComfyUI."),
        TempSource(tokens: ["mlx-", "mlx_"], prefixOnly: true, source: "MLX", title: "MLX temp data", detail: "Temporary files from Apple MLX model tools."),
        TempSource(tokens: ["llama", "gguf", "vllm"], prefixOnly: false, source: "Local LLM", title: "Local model temp data",
                   detail: "Temporary files from llama.cpp, vLLM or a similar local model runner."),
        TempSource(tokens: ["langchain", "chromadb", "chroma-", "llamaindex", "llama_index"], prefixOnly: false, source: "LangChain / Chroma", title: "AI app temp data",
                   detail: "Temporary files from LangChain, LlamaIndex or a Chroma vector store."),
        TempSource(tokens: ["perplexity"], prefixOnly: false, source: "Perplexity", title: "Perplexity temp data", detail: "Temporary files from Perplexity."),
    ]

    private static func tempSource(for lowercasedName: String) -> TempSource? {
        tempSources.first { s in
            s.tokens.contains { s.prefixOnly ? lowercasedName.hasPrefix($0) : lowercasedName.contains($0) }
        }
    }

    private static let claudeScratchPattern = try! NSRegularExpression(pattern: "^claude-[0-9]+$")

    private static func scanTemp(_ ctx: inout AIJunkContext) {
        var roots = [URL(fileURLWithPath: "/private/tmp", isDirectory: true),
                     URL(fileURLWithPath: AIJunkContext.realPath(NSTemporaryDirectory()), isDirectory: true)]
        if roots[0].path == roots[1].path { roots.removeLast() }
        for root in roots {
            for child in AIJunkContext.list(root) {
                if Task.isCancelled { return }
                let name = child.lastPathComponent
                let lower = name.lowercased()
                if lower.hasPrefix("cc-daemon") || lower == "cc-socks" || lower.hasPrefix("com.govindsr.reclaim") { continue }
                guard AIJunkContext.isFileOrFolder(child) else { continue }  // skip sockets and pipes
                if claudeScratchPattern.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)) != nil {
                    scanClaudeScratch(child, &ctx)
                    continue
                }
                guard let source = tempSource(for: lower) else { continue }
                ctx.add(child, category: .temp, source: source.source, title: source.title, detail: source.detail,
                        safety: .safe, requiresIdle: ctx.idle)
            }
        }
        // Agent-owned temp folders.
        for session in AIJunkContext.list(at(".gemini/tmp")) {
            ctx.add(session, category: .temp, source: "Gemini CLI", title: "Gemini CLI scratch · \(session.lastPathComponent.prefix(12))",
                    detail: "Per-session scratch files from the Gemini CLI.", safety: .safe, requiresIdle: ctx.idle)
        }
    }

    /// `/tmp/claude-<uid>/<project>/<session>` — one item per session.
    private static func scanClaudeScratch(_ base: URL, _ ctx: inout AIJunkContext) {
        for project in AIJunkContext.list(base) where FS.isDirectory(project) {
            let label = claudeProjectLabel(project.lastPathComponent)
            let sessions = AIJunkContext.list(project).filter { FS.isDirectory($0) }
            if sessions.isEmpty {
                ctx.add(project, category: .temp, source: "Claude Code", title: "Agent scratch · \(label)",
                        detail: "Scratch output from Claude Code sessions in this project.", safety: .safe, requiresIdle: ctx.idle)
            }
            for session in sessions {
                ctx.add(session, category: .temp, source: "Claude Code", title: "Agent scratch · \(label)",
                        detail: "Task output and temp files from one Claude Code session (\(session.lastPathComponent.prefix(8))).",
                        safety: .safe, requiresIdle: ctx.idle)
            }
        }
    }

    /// "-Users-me-Github-App" → "Github-App" (Claude Code encodes project paths this way).
    static func claudeProjectLabel(_ encoded: String) -> String {
        let homeKey = FS.home.path.replacingOccurrences(of: "/", with: "-")
        if encoded == homeKey { return "~" }
        if encoded.hasPrefix(homeKey + "-") { return String(encoded.dropFirst(homeKey.count + 1)) }
        return encoded.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    // MARK: Claude Code

    private static func scanClaudeCode(_ ctx: inout AIJunkContext) {
        let base = at(".claude")
        guard FS.exists(base) else { return }
        let history = max(ctx.idle, thirtyDays)

        // Session transcripts. Only `<session>.jsonl` and its `<session>/` sidecar — never `memory/` or anything else.
        for project in AIJunkContext.list(at(".claude/projects")) where FS.isDirectory(project) {
            if Task.isCancelled { return }
            let label = claudeProjectLabel(project.lastPathComponent)
            let transcripts = AIJunkContext.list(project).filter { $0.pathExtension == "jsonl" }
            guard !transcripts.isEmpty else { continue }
            let cwd = transcripts.lazy.compactMap { readClaudeCwd($0) }.first
            let orphaned = cwd.map { !FS.exists(URL(fileURLWithPath: $0)) } ?? false
            for file in transcripts {
                let session = file.deletingPathExtension().lastPathComponent
                var targets = [file]
                let sidecar = project.appendingPathComponent(session, isDirectory: true)
                if FS.isDirectory(sidecar) { targets.append(sidecar) }
                let detail = orphaned
                    ? "A Claude Code transcript whose project folder (\(FS.abbreviate(cwd ?? ""))) no longer exists, so it can't be resumed."
                    : "A Claude Code conversation you could still continue with claude --resume."
                ctx.addGroup(display: file, targets: targets, category: .agents, source: "Claude Code",
                             title: "Session transcript · \(label)", detail: detail,
                             safety: orphaned ? .safe : .caution, requiresIdle: orphaned ? ctx.idle : history)
            }
        }

        for dir in AIJunkContext.list(at(".claude/file-history")) where FS.isDirectory(dir) {
            ctx.add(dir, category: .agents, source: "Claude Code", title: "Edit checkpoints · session \(dir.lastPathComponent.prefix(8))",
                    detail: "Backups Claude Code keeps so it can rewind edits in an old session.", safety: .safe, requiresIdle: history)
        }

        let small: [(String, String, String)] = [
            ("shell-snapshots", "Shell snapshots", "Copies of your shell environment taken when sessions start."),
            ("todos", "Old to-do lists", "Task lists from finished Claude Code sessions."),
            ("debug", "Debug logs", "Diagnostic logs written by Claude Code."),
            ("paste-cache", "Paste cache", "Copies of large pastes from old sessions."),
        ]
        for (sub, title, detail) in small {
            ctx.addStaleFiles(in: at(".claude/\(sub)"), category: .agents, source: "Claude Code", title: title, detail: detail, safety: .safe)
        }

        // Older native installs of the CLI.
        let current = AIJunkContext.realPath(at(".local/bin/claude").path)
        scanOldVersions(in: at(".local/share/claude/versions"), current: current, source: "Claude Code",
                        title: "Old Claude Code version", safety: .safe, &ctx)
    }

    /// Reads the working directory recorded in a Claude Code transcript.
    static func readClaudeCwd(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 256 * 1024), let text = String(data: data, encoding: .utf8) else { return nil }
        guard let start = text.range(of: "\"cwd\":\"") else { return nil }
        var path = ""
        var escaped = false
        for ch in text[start.upperBound...] {
            if escaped { path.append(ch); escaped = false; continue }
            if ch == "\\" { escaped = true; continue }
            if ch == "\"" { break }
            path.append(ch)
        }
        return path.hasPrefix("/") ? path : nil
    }

    // MARK: Other agents

    private static func scanOtherAgents(_ ctx: inout AIJunkContext) {
        let history = max(ctx.idle, thirtyDays)

        // Codex: sessions/YYYY/MM/DD
        for year in AIJunkContext.list(at(".codex/sessions")) where FS.isDirectory(year) {
            for month in AIJunkContext.list(year) where FS.isDirectory(month) {
                for day in AIJunkContext.list(month) where FS.isDirectory(day) {
                    ctx.add(day, category: .agents, source: "Codex",
                            title: "Codex sessions · \(year.lastPathComponent)-\(month.lastPathComponent)-\(day.lastPathComponent)",
                            detail: "Logs of that day's Codex conversations, used by codex resume.", safety: .caution, requiresIdle: history)
                }
            }
        }
        ctx.addStaleFiles(in: at(".codex/log"), category: .agents, source: "Codex", title: "Codex logs",
                          detail: "Diagnostic logs written by the Codex CLI.", safety: .safe)

        // Gemini / Antigravity
        for rec in AIJunkContext.list(at(".gemini/antigravity-ide/browser_recordings")) {
            ctx.add(rec, category: .agents, source: "Antigravity", title: "Agent browser recording · \(rec.lastPathComponent.prefix(16))",
                    detail: "A recording of an agent's browser session in Antigravity.", safety: .safe, requiresIdle: max(ctx.idle, 7 * 86_400))
        }
        for (sub, title) in [("conversations", "Antigravity conversation"), ("brain", "Antigravity agent workspace")] {
            for item in AIJunkContext.list(at(".gemini/antigravity-ide/\(sub)")) {
                ctx.add(item, category: .agents, source: "Antigravity", title: "\(title) · \(item.lastPathComponent.prefix(12))",
                        detail: "History and artifacts from an old Antigravity agent session.", safety: .caution, requiresIdle: history)
            }
        }

        // Continue
        for session in AIJunkContext.list(at(".continue/sessions")) {
            ctx.add(session, category: .agents, source: "Continue", title: "Continue session · \(session.deletingPathExtension().lastPathComponent.prefix(12))",
                    detail: "A saved chat from the Continue extension.", safety: .caution, requiresIdle: history)
        }

        // VS Code-family editors keep per-workspace AI chat and index data; flag it when the folder is gone.
        for app in ["Cursor", "Windsurf", "Trae", "Kiro", "Void", "Antigravity", "Code", "VSCodium"] {
            for ws in AIJunkContext.list(appSupport(app).appendingPathComponent("User/workspaceStorage")) where FS.isDirectory(ws) {
                guard let folder = workspaceFolder(ws), !FS.exists(folder) else { continue }
                ctx.add(ws, category: .agents, source: app == "Code" ? "VS Code" : app,
                        title: "Workspace data · \(folder.lastPathComponent)",
                        detail: "Chat history, indexes and state for \(FS.abbreviate(folder.path)), which no longer exists.",
                        safety: .safe, requiresIdle: nil)
            }
        }
    }

    /// The local folder a VS Code-style workspaceStorage entry belongs to.
    private static func workspaceFolder(_ ws: URL) -> URL? {
        guard let data = try? Data(contentsOf: ws.appendingPathComponent("workspace.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = (json["folder"] ?? json["workspace"]) as? String,
              let url = URL(string: raw), url.isFileURL else { return nil }
        return url
    }

    // MARK: Projects

    private static func scanProjects(_ ctx: inout AIJunkContext) {
        let names = ["Github", "GitHub", "Developer", "Projects", "Code", "code", "src", "repos", "Repos", "workspace", "Work", "dev", "Sites", "Documents/GitHub"]
        var roots: [URL] = []
        var seen = Set<String>()
        for name in names {
            let url = at(name)
            guard FS.isDirectory(url) else { continue }
            if seen.insert(AIJunkContext.realPath(url.path).lowercased()).inserted { roots.append(url) }
        }
        let skip: Set<String> = ["node_modules", ".git", "Pods", "build", "DerivedData", ".build", "venv", ".venv", "dist", "target", "vendor", "__pycache__"]
        var budget = 150_000
        var queue: [(URL, Int)] = roots.map { ($0, 0) }
        while !queue.isEmpty, budget > 0 {
            if Task.isCancelled { return }
            let (dir, depth) = queue.removeFirst()
            for child in AIJunkContext.list(dir) {
                budget -= 1
                let name = child.lastPathComponent
                guard FS.isDirectory(child) else { continue }
                if name == ".claude" {
                    let repo = dir.lastPathComponent
                    for wt in AIJunkContext.list(child.appendingPathComponent("worktrees")) where FS.isDirectory(wt) {
                        ctx.add(wt, category: .agents, source: "Claude Code", title: "Agent worktree · \(repo)/\(wt.lastPathComponent)",
                                detail: "A git worktree an AI agent created. Check nothing in it is still needed, then run git worktree prune in \(repo).",
                                safety: .caution, requiresIdle: ctx.idle)
                    }
                    continue
                }
                if name.hasPrefix(".aider.tags.cache") {
                    ctx.add(child, category: .agents, source: "Aider", title: "Aider repo map cache · \(dir.lastPathComponent)",
                            detail: "Aider's index of this repository. It's rebuilt automatically.", safety: .safe, requiresIdle: nil)
                    continue
                }
                if name.hasPrefix(".") || skip.contains(name) || name.hasSuffix(".app") { continue }
                if depth < 4 { queue.append((child, depth + 1)) }
            }
        }
    }

    // MARK: App caches

    private static let electronCaches: [(String, String)] = [
        ("Cache", "Web content cache that rebuilds as the app runs."),
        ("Code Cache", "Compiled script cache that rebuilds as the app runs."),
        ("GPUCache", "Graphics shader cache."),
        ("DawnCache", "Graphics shader cache."),
        ("DawnGraphiteCache", "Graphics shader cache."),
        ("DawnWebGPUCache", "Graphics shader cache."),
        ("GraphiteDawnCache", "Graphics shader cache."),
        ("ShaderCache", "Graphics shader cache."),
        ("CachedData", "Cached editor data, including leftovers from older versions."),
        ("CachedExtensionVSIXs", "Extension installers kept after the extensions were installed."),
        ("CachedProfilesData", "Cached profile data that rebuilds on launch."),
        ("logs", "Log files."),
        ("Crashpad/completed", "Crash reports that were already handled."),
        ("Service Worker/CacheStorage", "Offline web cache that rebuilds as the app runs."),
        ("Service Worker/ScriptCache", "Offline script cache that rebuilds as the app runs."),
    ]

    private static func scanAppCaches(_ ctx: inout AIJunkContext) {
        let apps = ["Claude", "Cursor", "Windsurf", "Trae", "Kiro", "Void", "Antigravity", "LM Studio", "Jan", "Msty", "Perplexity", "ChatGPT"]
        for app in apps {
            let base = appSupport(app)
            guard FS.isDirectory(base) else { continue }
            for (sub, detail) in electronCaches {
                ctx.add(base.appendingPathComponent(sub, isDirectory: true), category: .caches, source: app,
                        title: "\(app) · \(sub)", detail: detail, safety: .safe, requiresIdle: nil, minBytes: 1_000_000, ownerApp: app)
            }
        }
        // Agent browser profile used by Antigravity.
        for sub in ["Default/Cache", "Default/Code Cache", "Default/GPUCache", "GrShaderCache", "ShaderCache"] {
            ctx.add(at(".gemini/antigravity-browser-profile/\(sub)"), category: .caches, source: "Antigravity",
                    title: "Agent browser · \(sub.replacingOccurrences(of: "Default/", with: ""))",
                    detail: "Cache of the browser Antigravity's agent drives. It rebuilds as the agent browses.",
                    safety: .safe, requiresIdle: nil, minBytes: 1_000_000, ownerApp: "Antigravity")
        }
        ctx.add(at(".codex/.tmp"), category: .caches, source: "Codex", title: "Codex plugin sync cache",
                detail: "Plugin marketplace data Codex downloads again when it needs it.", safety: .safe, requiresIdle: ctx.idle, minBytes: 1_000_000, ownerApp: "codex")
        ctx.add(at(".codex/cache"), category: .caches, source: "Codex", title: "Codex cache",
                detail: "Cached tool and plugin catalogs that Codex refreshes on its own.", safety: .safe, requiresIdle: ctx.idle, minBytes: 1_000_000, ownerApp: "codex")
        ctx.add(at(".cache/huggingface/xet"), category: .caches, source: "Hugging Face", title: "Hugging Face download cache",
                detail: "Chunk cache that speeds up repeat downloads. Downloaded models are kept.", safety: .safe, requiresIdle: nil, minBytes: 1_000_000)
        ctx.add(at(".continue/index"), category: .caches, source: "Continue", title: "Continue code index",
                detail: "Continue's search index of your code. It's rebuilt automatically.", safety: .safe, requiresIdle: nil, minBytes: 1_000_000)

        for (path, source) in [(".ollama/logs", "Ollama"), (".lmstudio/server-logs", "LM Studio"), (".cache/lm-studio/server-logs", "LM Studio")] {
            ctx.addStaleFiles(in: at(path), category: .caches, source: source, title: "\(source) logs",
                              detail: "Server logs from the local model runner.", safety: .safe)
        }

        // Old bundled versions.
        scanOldVersions(in: appSupport("Claude").appendingPathComponent("claude-code"), current: nil, source: "Claude",
                        title: "Old Claude Code build bundled with Claude", safety: .safe, &ctx)
        scanOldEngineVersions(in: at(".lmstudio/extensions/backends"), &ctx)
    }

    /// Lists every version except the newest and the one `current` points into.
    private static func scanOldVersions(in dir: URL, current: String?, source: String, title: String, safety: AIJunkSafety, _ ctx: inout AIJunkContext) {
        let versions = AIJunkContext.list(dir).filter { $0.lastPathComponent.first?.isNumber == true }
            .sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedAscending }
        guard let newest = versions.last, versions.count > 1 else { return }
        for v in versions.dropLast() {
            let real = AIJunkContext.realPath(v.path)
            if let current, current == real || current.hasPrefix(real + "/") { continue }
            ctx.add(v, category: .caches, source: source, title: "\(title) \(v.lastPathComponent)",
                    detail: "An older version kept after an update. The newest is \(newest.lastPathComponent).",
                    safety: safety, requiresIdle: nil)
        }
    }

    /// LM Studio keeps every engine version it ever installed: "mlx-llm-mac-arm64-…-1.10.1".
    private static func scanOldEngineVersions(in dir: URL, _ ctx: inout AIJunkContext) {
        var families: [String: [(URL, String)]] = [:]
        for engine in AIJunkContext.list(dir) where FS.isDirectory(engine) {
            let name = engine.lastPathComponent
            guard let dash = name.lastIndex(of: "-") else { continue }
            let version = String(name[name.index(after: dash)...])
            guard version.first?.isNumber == true else { continue }
            families[String(name[..<dash]), default: []].append((engine, version))
        }
        for (family, members) in families where members.count > 1 {
            let sorted = members.sorted { $0.1.compare($1.1, options: .numeric) == .orderedAscending }
            let newest = sorted.last!.1
            for (url, version) in sorted.dropLast() {
                ctx.add(url, category: .caches, source: "LM Studio", title: "Old LM Studio engine · \(family.components(separatedBy: "-").first ?? family) \(version)",
                        detail: "LM Studio keeps old engine versions after updating. The newest is \(newest); keep this one only if you pinned it.",
                        safety: .caution, requiresIdle: nil)
            }
        }
    }

    // MARK: Models

    private static func scanModels(_ ctx: inout AIJunkContext) {
        let env = ProcessInfo.processInfo.environment
        let hfHome = env["HF_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? at(".cache/huggingface")
        let hub = env["HF_HUB_CACHE"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? hfHome.appendingPathComponent("hub")
        for repo in AIJunkContext.list(hub) where FS.isDirectory(repo) {
            let parts = repo.lastPathComponent.components(separatedBy: "--")
            guard parts.count >= 2, ["models", "datasets", "spaces"].contains(parts[0]) else { continue }
            let kind = parts[0] == "models" ? "Model" : (parts[0] == "datasets" ? "Dataset" : "Space")
            ctx.add(repo, category: .models, source: "Hugging Face", title: parts.dropFirst().joined(separator: "/"),
                    detail: "\(kind) downloaded from Hugging Face (also used by MLX and Transformers).",
                    safety: .caution, requiresIdle: nil, style: .model)
        }
        for ds in AIJunkContext.list(hfHome.appendingPathComponent("datasets")) where FS.isDirectory(ds) {
            ctx.add(ds, category: .models, source: "Hugging Face", title: "Dataset cache · \(ds.lastPathComponent)",
                    detail: "Processed dataset files from the datasets library.", safety: .caution, requiresIdle: nil, style: .model)
        }

        scanOllama(env["OLLAMA_MODELS"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? at(".ollama/models"), &ctx)

        for root in [at(".lmstudio/models"), at(".cache/lm-studio/models")] {
            for publisher in AIJunkContext.list(root) where FS.isDirectory(publisher) {
                for model in AIJunkContext.list(publisher) where FS.isDirectory(model) {
                    ctx.add(model, category: .models, source: "LM Studio", title: "\(publisher.lastPathComponent)/\(model.lastPathComponent)",
                            detail: "Model downloaded in LM Studio.", safety: .caution, requiresIdle: nil, style: .model)
                }
            }
        }

        let modelExtensions: Set<String> = ["gguf", "bin", "safetensors", "pt", "pth", "onnx", "ckpt", "mlmodel", "h5", "keras", "tflite"]
        let flat: [(String, String, String)] = [
            ("Library/Application Support/nomic.ai/GPT4All", "GPT4All", "Model downloaded in GPT4All."),
            (".cache/whisper", "Whisper", "Speech-recognition model used by Whisper."),
            (".cache/clip", "CLIP", "Image–text model used by CLIP."),
            (".cache/torch/hub/checkpoints", "PyTorch", "Model weights downloaded through torch.hub."),
            (".keras/models", "Keras", "Model weights downloaded by Keras."),
            (".u2net", "rembg", "Background-removal model used by rembg."),
            (".cache/chroma/onnx_models", "Chroma", "Embedding model used by the Chroma vector store."),
            (".cache/torch/sentence_transformers", "Sentence Transformers", "Embedding model used by sentence-transformers."),
            (".diffusionbee/downloads", "DiffusionBee", "Image model downloaded in DiffusionBee."),
            ("jan/models", "Jan", "Model downloaded in Jan."),
            ("Library/Application Support/Jan/data/models", "Jan", "Model downloaded in Jan."),
            ("Library/Application Support/Jan/data/llamacpp/models", "Jan", "Model downloaded in Jan."),
            (".cache/modelscope/hub", "ModelScope", "Model downloaded from ModelScope."),
        ]
        for (path, source, detail) in flat {
            for item in AIJunkContext.list(at(path)) {
                let isDir = FS.isDirectory(item)
                if !isDir, !modelExtensions.contains(item.pathExtension.lowercased()) { continue }
                ctx.add(item, category: .models, source: source, title: item.lastPathComponent, detail: detail,
                        safety: .caution, requiresIdle: nil, minBytes: 5_000_000, style: .model)
            }
        }
        for repo in AIJunkContext.list(at(".cache/torch/hub")) where FS.isDirectory(repo) && repo.lastPathComponent != "checkpoints" {
            ctx.add(repo, category: .models, source: "PyTorch", title: repo.lastPathComponent, detail: "Model code and weights downloaded through torch.hub.",
                    safety: .caution, requiresIdle: nil, minBytes: 5_000_000, style: .model)
        }

        let drawThings = FS.library("Containers/com.liuliu.draw-things")
        if FS.exists(drawThings) {
            let models = drawThings.appendingPathComponent("Data/Documents/Models")
            if FS.canList(models) {
                for m in AIJunkContext.list(models) {
                    ctx.add(m, category: .models, source: "Draw Things", title: m.lastPathComponent, detail: "Image model downloaded in Draw Things.",
                            safety: .caution, requiresIdle: nil, minBytes: 5_000_000, style: .model)
                }
            } else {
                ctx.blocked.append("Draw Things models")
            }
        }

        for bundle in AIJunkContext.list(appSupport("Claude").appendingPathComponent("vm_bundles")) where bundle.pathExtension == "bundle" {
            ctx.add(bundle, category: .models, source: "Claude", title: "Claude sandbox VM image",
                    detail: "The Linux VM Claude uses to run code for you. It downloads again (several GB) when a feature needs it.",
                    safety: .caution, requiresIdle: nil, style: .model)
        }
    }

    private struct OllamaManifest: Decodable {
        struct Layer: Decodable { let digest: String }
        let config: Layer?
        let layers: [Layer]?
        var digests: [String] { ((config.map { [$0] } ?? []) + (layers ?? [])).map(\.digest) }
    }

    /// One item per Ollama model: its manifest plus only the layers no other model shares.
    private static func scanOllama(_ root: URL, _ ctx: inout AIJunkContext) {
        let manifests = root.appendingPathComponent("manifests")
        guard FS.isDirectory(manifests) else { return }
        var parsed: [(url: URL, name: String, digests: [String])] = []
        FS.walkFiles([manifests], includeHidden: false, intoPackages: true) { url, _ in
            guard let data = try? Data(contentsOf: url), let m = try? JSONDecoder().decode(OllamaManifest.self, from: data) else { return true }
            // manifests/<registry>/<namespace>/<model>/<tag>
            let comps = url.pathComponents
            guard comps.count >= 3 else { return true }
            let tag = comps[comps.count - 1], model = comps[comps.count - 2], namespace = comps[comps.count - 3]
            let name = namespace == "library" ? "\(model):\(tag)" : "\(namespace)/\(model):\(tag)"
            parsed.append((url, name, m.digests))
            return true
        }
        var refs: [String: Int] = [:]
        for p in parsed { for d in Set(p.digests) { refs[d, default: 0] += 1 } }
        let blobs = root.appendingPathComponent("blobs")
        for p in parsed {
            let unique = Set(p.digests).filter { refs[$0] == 1 }
            let shared = Set(p.digests).count - unique.count
            let blobURLs = unique.map { blobs.appendingPathComponent($0.replacingOccurrences(of: ":", with: "-")) }.filter { FS.exists($0) }
            let detail = shared > 0
                ? "Model pulled with Ollama. It shares \(Fmt.count(shared, "layer")) with other models; only its own layers are removed. Same as ollama rm."
                : "Model pulled with Ollama. Same as running ollama rm."
            ctx.addGroup(display: p.url, targets: [p.url] + blobURLs, category: .models, source: "Ollama", title: p.name,
                         detail: detail, safety: .caution, requiresIdle: nil, style: .model)
        }
    }

    // MARK: Generated images

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "webp", "heic", "avif", "gif"]
    private static let midjourneyPattern = try! NSRegularExpression(
        pattern: "^[a-z0-9]+_.+_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}(_[0-9])?\\.(png|webp|jpg|jpeg)$")
    private static let automatic1111Pattern = try! NSRegularExpression(pattern: "^[0-9]{5}-[0-9]+(-.*)?\\.(png|jpg|jpeg|webp)$")

    static func generatedSource(forName name: String) -> String? {
        let n = name.lowercased()
        let range = NSRange(n.startIndex..., in: n)
        if n.hasPrefix("dall·e") || n.hasPrefix("dall-e") || n.hasPrefix("dalle") { return "DALL·E" }
        if n.hasPrefix("chatgpt image") || n.hasPrefix("chatgpt_image") { return "ChatGPT" }
        if n.hasPrefix("gemini_generated_image") || n.hasPrefix("gemini generated image") { return "Gemini" }
        if n.contains("firefly") { return "Adobe Firefly" }
        if n.hasPrefix("leonardo_") { return "Leonardo" }
        if n.hasPrefix("ideogram") { return "Ideogram" }
        if n.contains("midjourney") || midjourneyPattern.firstMatch(in: n, range: range) != nil { return "Midjourney" }
        if n.hasPrefix("comfyui_") || n.hasPrefix("comfyui-") { return "ComfyUI" }
        if n.hasPrefix("grok-image") || n.hasPrefix("grok_image") || n.hasPrefix("grok image") { return "Grok" }
        if n.hasPrefix("copilot_") || n.hasPrefix("designer_") || n.hasPrefix("bing image creator") { return "Microsoft Copilot" }
        if n.hasPrefix("flux_") || n.hasPrefix("flux-") { return "FLUX" }
        if n.hasPrefix("imagen") { return "Imagen" }
        if n.hasPrefix("generated image") || n.hasPrefix("generated_image") || n.hasPrefix("ai_generated") || n.hasPrefix("ai-generated") { return "AI image" }
        if automatic1111Pattern.firstMatch(in: n, range: range) != nil { return "Stable Diffusion" }
        return nil
    }

    /// Checks IPTC "digital source type" and the PNG/EXIF software field.
    static func generatedSource(fromMetadataOf url: URL) -> String? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        if let meta = CGImageSourceCopyMetadataAtIndex(src, 0, nil),
           let tag = CGImageMetadataCopyTagWithPath(meta, nil, "Iptc4xmpExt:DigitalSourceType" as CFString),
           let value = CGImageMetadataTagCopyValue(tag) as? String,
           value.contains("trainedAlgorithmicMedia") {
            return "AI image"
        }
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
        let png = props[kCGImagePropertyPNGDictionary] as? [CFString: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let software = ((png?[kCGImagePropertyPNGSoftware] as? String) ?? (tiff?[kCGImagePropertyTIFFSoftware] as? String) ?? "").lowercased()
        let known: [(String, String)] = [("dall", "DALL·E"), ("midjourney", "Midjourney"), ("firefly", "Adobe Firefly"), ("stable diffusion", "Stable Diffusion"),
                                         ("novelai", "NovelAI"), ("comfyui", "ComfyUI"), ("imagen", "Imagen"), ("openai", "ChatGPT"), ("google ai", "Gemini")]
        return known.first { software.contains($0.0) }?.1
    }

    private static func scanGenerated(_ ctx: inout AIJunkContext) {
        var metadataChecks = 0
        FS.walkFiles([FS.downloads, FS.desktop, FS.pictures]) { url, values in
            guard imageExtensions.contains(url.pathExtension.lowercased()) else { return true }
            var source = generatedSource(forName: url.lastPathComponent)
            var byMetadata = false
            if source == nil, metadataChecks < 4000, FS.allocated(values) < 60_000_000 {
                metadataChecks += 1
                source = generatedSource(fromMetadataOf: url)
                byMetadata = source != nil
            }
            guard let source else { return true }
            let detail = byMetadata
                ? "Its metadata says it was made with \(source)."
                : "Named like an image exported from \(source)."
            ctx.add(url, category: .generated, source: source, title: url.lastPathComponent, detail: detail,
                    safety: .caution, requiresIdle: nil, style: .plain)
            return !Task.isCancelled
        }
    }
}

// MARK: - Context

/// Accumulates items while probes run.
struct AIJunkContext {
    enum DetailStyle { case idle, model, plain }

    let idle: TimeInterval
    var open = AIOpenFiles.empty
    var items: [AIJunkItem] = []
    var seen = Set<String>()
    var skippedRecent = 0
    var skippedRecentBytes: Int64 = 0
    var blocked: [String] = []

    /// Measures and adds one path. Items touched within `requiresIdle` are skipped (counted, not listed).
    mutating func add(_ url: URL, category: AIJunkCategory, source: String, title: String, detail: String,
                      safety: AIJunkSafety, requiresIdle: TimeInterval?, minBytes: Int64 = 1, style: DetailStyle = .idle,
                      ownerApp: String? = nil) {
        addGroup(display: url, targets: [url], category: category, source: source, title: title, detail: detail,
                 safety: safety, requiresIdle: requiresIdle, minBytes: minBytes, style: style, ownerApp: ownerApp)
    }

    /// Adds one item made of several paths (e.g. an Ollama manifest and its layers).
    mutating func addGroup(display: URL, targets: [URL], category: AIJunkCategory, source: String, title: String, detail: String,
                           safety: AIJunkSafety, requiresIdle: TimeInterval?, minBytes: Int64 = 1, style: DetailStyle = .idle,
                           ownerApp: String? = nil) {
        guard !Task.isCancelled, FS.exists(display), seen.insert(display.path).inserted else { return }
        var measured: [AIJunkTarget] = []
        var newest: Date?
        var accessed: Date?
        for t in targets {
            let m = AIMeasure.measure(t)
            measured.append(AIJunkTarget(url: t, bytes: m.bytes))
            if let n = m.newest, n > (newest ?? .distantPast) { newest = n }
            if let a = m.accessed, a > (accessed ?? .distantPast) { accessed = a }
        }
        let bytes = measured.reduce(0) { $0 + $1.bytes }
        guard bytes >= minBytes else { return }
        if let requiresIdle, let newest, Date().timeIntervalSince(newest) < requiresIdle {
            skippedRecent += 1
            skippedRecentBytes += bytes
            return
        }
        var inUse: String? = ownerApp.flatMap { open.isRunning($0) ? $0 : nil }
        for t in targets where inUse == nil {
            if let user = open.user(of: Self.realPath(t.path)) { inUse = user; break }
        }
        let text: String
        switch style {
        case .idle:
            text = newest.map { "\(detail) Untouched for \(Fmt.age($0))." } ?? detail
        case .model:
            let lastUse = [newest, accessed].compactMap { $0 }.max()
            text = lastUse.map { "\(detail) Last used about \(Fmt.age($0)) ago." } ?? detail
        case .plain:
            text = detail
        }
        items.append(AIJunkItem(id: display.path, category: category, source: source, title: title, detail: text, safety: safety,
                                url: display, targets: measured, lastActivity: newest, isDirectory: FS.isDirectory(display), inUseBy: inUse))
    }

    /// Groups a folder's files that haven't changed within the idle window into one item (the folder itself stays).
    mutating func addStaleFiles(in folder: URL, category: AIJunkCategory, source: String, title: String, detail: String, safety: AIJunkSafety) {
        guard FS.isDirectory(folder), seen.insert(folder.path + "#stale").inserted else { return }
        let cutoff = Date().addingTimeInterval(-idle)
        var targets: [AIJunkTarget] = []
        var newest: Date?
        FS.walkFiles([folder], includeHidden: true, intoPackages: true) { url, v in
            guard let mod = v.contentModificationDate, mod < cutoff else { return true }
            if open.user(of: Self.realPath(url.path)) != nil { return true }
            targets.append(AIJunkTarget(url: url, bytes: FS.allocated(v)))
            if mod > (newest ?? .distantPast) { newest = mod }
            return true
        }
        let bytes = targets.reduce(0) { $0 + $1.bytes }
        guard bytes > 0 else { return }
        items.append(AIJunkItem(id: folder.path + "#stale", category: category, source: source,
                                title: "\(title) (\(Fmt.count(targets.count, "file")))",
                                detail: "\(detail) Only files untouched for \(Fmt.age(cutoff)) or more.",
                                safety: safety, url: folder, targets: targets, lastActivity: newest, isDirectory: true, inUseBy: nil))
    }

    static func realPath(_ path: String) -> String {
        guard let p = Darwin.realpath(path, nil) else { return path }
        defer { free(p) }
        return String(cString: p)
    }

    /// Children including hidden ones; empty if unreadable.
    static func list(_ url: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [])) ?? []
    }

    static func isFileOrFolder(_ url: URL) -> Bool {
        guard let v = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]) else { return false }
        return v.isSymbolicLink != true && (v.isRegularFile == true || v.isDirectory == true)
    }
}

/// Size and newest activity of a file or folder (hidden files and package contents included).
enum AIMeasure {
    struct Result {
        var bytes: Int64 = 0
        var newest: Date?
        var accessed: Date?
    }

    private static let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey,
                                                 .fileAllocatedSizeKey, .fileSizeKey, .contentModificationDateKey, .contentAccessDateKey]

    static func measure(_ url: URL) -> Result {
        var r = Result()
        let keySet = Set(keys)
        guard let v = try? url.resourceValues(forKeys: keySet) else { return r }
        r.newest = v.contentModificationDate
        if v.isSymbolicLink == true { return r }
        if v.isDirectory != true {
            r.bytes = FS.allocated(v)
            r.accessed = v.contentAccessDate
            return r
        }
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else { return r }
        var n = 0
        for case let child as URL in e {
            n += 1
            if n & 511 == 0, Task.isCancelled { break }
            guard let cv = try? child.resourceValues(forKeys: keySet), cv.isSymbolicLink != true else { continue }
            if let m = cv.contentModificationDate, m > (r.newest ?? .distantPast) { r.newest = m }
            if cv.isRegularFile == true {
                r.bytes += FS.allocated(cv)
                if let a = cv.contentAccessDate, a > (r.accessed ?? .distantPast) { r.accessed = a }
            }
        }
        return r
    }
}

/// Which paths running processes have open (files and working directories), from `lsof`.
struct AIOpenFiles: Sendable {
    private let sorted: [String]
    private let owners: [String: String]
    /// Names of running processes (as lsof reports them, e.g. "Cursor Helper (Renderer)").
    private let commands: Set<String>
    let available: Bool

    static let empty = AIOpenFiles(sorted: [], owners: [:], commands: [], available: false)

    private init(sorted: [String], owners: [String: String], commands: Set<String>, available: Bool) {
        self.sorted = sorted
        self.owners = owners
        self.commands = commands
        self.available = available
    }

    /// Whether an app is running: a process named exactly `app`, or `app` followed by a space ("Claude Helper").
    /// Case-sensitive, so the `claude` CLI doesn't count as the Claude desktop app.
    func isRunning(_ app: String) -> Bool {
        commands.contains { $0 == app || $0.hasPrefix(app + " ") }
    }

    static func load() -> AIOpenFiles {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-n", "-P", "-w", "+c", "0", "-F", "pcn"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return .empty }
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: watchdog)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        guard !data.isEmpty else { return .empty }

        var owners: [String: String] = [:]
        var commands = Set<String>()
        var command = ""
        String(decoding: data, as: UTF8.self).enumerateLines { line, _ in
            guard let first = line.first else { return }
            if first == "c" {
                command = String(line.dropFirst())
                commands.insert(command)
            } else if first == "n" {
                var name = String(line.dropFirst())
                guard name.hasPrefix("/") else { return }
                if name.hasSuffix(" (deleted)") { name.removeLast(" (deleted)".count) }
                if owners[name] == nil { owners[name] = command }
            }
        }
        return AIOpenFiles(sorted: owners.keys.sorted(), owners: owners, commands: commands, available: true)
    }

    /// The process that has `path`, or anything inside it, open.
    func user(of path: String) -> String? {
        if let owner = owners[path] { return owner }
        let prefix = path.hasSuffix("/") ? path : path + "/"
        var lo = 0, hi = sorted.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if sorted[mid] < prefix { lo = mid + 1 } else { hi = mid }
        }
        if lo < sorted.count, sorted[lo].hasPrefix(prefix) { return owners[sorted[lo]] }
        return nil
    }
}
