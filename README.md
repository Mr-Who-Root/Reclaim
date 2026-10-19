# Reclaim

**Website:** https://mr-who-root.github.io/Reclaim/ · **Download:** [latest release](https://github.com/Mr-Who-Root/Reclaim/releases/latest)

A native macOS disk-space cleaner with **every tool unlocked** — no subscription, no account, no tracking. Its only network request is a check for new releases on GitHub (you can turn it off).
Reclaim looks first, explains every suggestion, and moves nothing until you approve it. Everything it removes
goes to the Trash, with Undo and a full history.

## Download

Grab the latest `Reclaim-<version>.dmg` from [Releases](../../releases), open it and drag **Reclaim** to
**Applications**.

Reclaim is signed ad hoc (not with a paid Apple Developer ID), so the first time you open it macOS will say it
can't verify the developer:

1. Open **Reclaim** from Applications once and dismiss the warning.
2. Go to **System Settings › Privacy & Security**, scroll down and click **Open Anyway** next to Reclaim.

Or, in Terminal: `xattr -dr com.apple.quarantine /Applications/Reclaim.app`

Because of the ad-hoc signature, macOS doesn't list Reclaim's desktop widget in the widget gallery for downloaded
builds. Building it yourself with a free Apple Development certificate brings the widget back (see
[Build from source](#build-from-source)).

Requires macOS 26 or later (Apple silicon or Intel).

## Tools

| Tool | What it does |
| --- | --- |
| **Mac Overview & Smart Scan** | Free space at a glance and one read-only pass across every section — all cleanup tools, Leftovers, your installed apps, Security Check, the Storage Map and the Trash. It only scans and reports; nothing is removed. |
| **Guided Cleanup** | Audits the areas you pick, builds a short plan you approve item by item, re-checks each item before acting, and keeps Undo per item. Includes an on-device assistant (Apple Intelligence) to ask about the review. |
| **Junk** | App caches, logs, saved window state, Chrome-family and Firefox caches, Xcode DerivedData / Archives / DeviceSupport, simulator caches, npm, Yarn, pip, Homebrew, CocoaPods, Gradle, Cargo, Android emulator images, iPhone backups and Mail downloads — each rule explains why it's safe. Also finds rebuildable build folders inside your code projects (`node_modules`, `target`, `build`, `Pods`, `.venv`…), only where the project's own files confirm what they are, split into old and recent projects so active work is left alone. |
| **AI Junk** | Stale agent scratch folders in `/tmp` and your temp folder, leftover Puppeteer/Playwright browser profiles, old Claude Code / Codex / Gemini / Antigravity / Continue sessions, agent git worktrees, Aider caches, orphaned Cursor/VS Code workspace data, AI app caches and old bundled versions, downloaded models (Hugging Face, Ollama — per model, only unshared layers — LM Studio, GPT4All, Whisper, PyTorch, Draw Things…) and AI-generated images. Anything a running app has open is left alone. |
| **Docker** | Build cache, dangling and unused images, stopped containers and orphaned volumes, read from `docker system df`. Each category explains what clearing it means and runs Docker's own prune command only after you confirm. Shown when the Docker CLI is installed (Docker Desktop, OrbStack, Colima, Rancher Desktop). |
| **Downloads** | Old installers, archives, unfinished and large downloads, with filters and a "Select Suggested" button. |
| **Duplicates** | Byte-for-byte duplicates (size → partial hash → SHA-256) with a protected keeper and selection rules. |
| **Photo Clutter** | Look-alike shots (Vision feature prints), screenshots and screen recordings in ~40 languages, and blurry photos. |
| **Large & Old Files** | Size, age and kind filters, list or sortable table, Quick Look. |
| **Storage Map** | Interactive treemap of any folder or the whole disk, drill-down, Collector for batch removal. |
| **Leftovers** | Support files left behind by apps you already removed, matched by bundle identifier and grouped per app. |
| **Uninstall an App** | Remove an app together with its caches, preferences, containers and other support files (Finder password fallback for protected apps). Lists apps in the Applications folders and anywhere else in your Home folder, such as your own builds, with when each was last opened and a filter for apps unused for 6+ months. |
| **Security Check** | Code-signature and notarisation status of every app, Deep Verify, login items and launch agents (flags ones pointing at missing programs), and where your downloads came from. Read-only; not antivirus. |
| **Trash** | Everything Reclaim moved, restore to the original folder, Open/Empty Trash. |

Also: **Exclusions** (right-click any result › Never Suggest This; manage them in Settings › Exclusions), **Settings** (granted folders and access check, appearance, language, scheduled scans with notifications,
launch at login, about), a **menu bar** monitor (free space, memory, CPU and CPU temperature, Smart Scan), a desktop **widget**,
**Shortcuts & Siri** actions, **Spotlight** entries for every tool, and `reclaim://` links (`reclaim://scan`,
`reclaim://ai`, `reclaim://settings/about`…).

**Appearance** — pick one of six accents and a style: **Vivid** (the whole window takes on your colour, with glass
cards), **Subtle** or **Classic**, in light or dark mode. The Dock icon and widget can follow the accent.

**Languages** — English, 简体中文, 繁體中文, Español, العربية, Português (Brasil), Français, Deutsch, 日本語, 한국어,
Русский, Italiano, Türkçe, Nederlands, Polski, Bahasa Indonesia, Tiếng Việt, ไทย, Українська, Svenska, हिन्दी,
മലയാളം and தமிழ். Switch in Settings › Language.

## Access

On first scan Reclaim asks for your Home folder once, then checks every location it reads (Desktop, Documents,
Downloads, Library, the temp folders…) so macOS can ask about each now rather than mid-scan. **Full Disk Access**
is optional and only needed for Mail, iPhone backups, the Trash and other apps' data
(Settings › Granted Folders shows what's readable).

## Build from source

```sh
# Xcode 26+ (macOS 26 SDK)
scripts/build.sh            # Release build → build/Reclaim.app
scripts/build.sh --install  # also copies it to /Applications and opens it
scripts/package.sh          # builds and creates build/Reclaim-<version>.dmg and .zip
scripts/make_icon.sh        # regenerates the app icon
```

Or open `Reclaim.xcodeproj` and run the **Reclaim** scheme.

The scripts sign with your **Developer ID Application** or **Apple Development** certificate when the Mac has one,
and ad hoc otherwise. macOS only lists the desktop widget in the widget gallery when it's signed with a certificate
that has a team, so to use the widget with your own build, add your Apple ID in **Xcode › Settings › Accounts** and
create a free Apple Development certificate (**Manage Certificates › +**) before building. To force a specific
identity, set `RECLAIM_SIGN_IDENTITY` (`-` for ad hoc).

## Project layout

```
Reclaim/            App target (SwiftUI)
  App/              App entry, AppModel, root navigation
  Core/             File system helpers, Trash + history, access checks, prefs, icon renderer
  UI/               Shared components
  Tools/<Tool>/     One folder per tool (model + view + scanner)
  Home/ Settings/ MenuBar/ Onboarding/ Intents/
  Localizable.xcstrings
ReclaimWidget/      Desktop widget extension
Shared/             Code shared by the app and the widget
Config/             Info.plists and entitlements
scripts/            Build, package and icon scripts
```

## Updates

Reclaim checks this repo's latest GitHub release once a day (Settings › About › Updates, or **Reclaim › Check for
Updates…**). When a newer version is out it shows a note on Home; one click downloads the release zip, verifies its
SHA-256 against the checksum GitHub publishes, checks the bundle identifier, version and code signature, swaps it in
place and reopens. Automatic checks can be turned off. Because builds are signed ad hoc, macOS may ask for folder
access again after an update.

## Privacy

Everything runs on your Mac. No analytics, no uploads, no account. The only request Reclaim makes is the update check. Reclaim never deletes permanently — you empty
the Trash yourself — and scheduled scans only ever find things.
