# Gitsidian

An iPhone app that opens a GitHub repository as an Obsidian-style vault. You browse and edit markdown as if the files were local, and your edits are committed back to GitHub in batches.

## What it does

- **Vaults = repos.** Sign in with a GitHub token, pick any repo + branch, and it's downloaded to the phone. Everything then works offline.
- **Obsidian-like UI.**
  - File explorer in a slide-out drawer (swipe from the left edge). Supports nested folders, new note/folder, rename, move, delete, and share.
  - Source editor with live markdown styling: bigger headings, dimmed markup, accented `[[wikilinks]]` and `#tags`, styled code, highlights, tasks, callouts and frontmatter.
  - Keyboard toolbar: undo/redo, `[[link]]`, checkbox, bullet, heading cycle, bold/italic/highlight/strike/code, indent/outdent, tag, and open the link under the cursor.
  - `[[` autocomplete with fuzzy note-name suggestions above the keyboard.
  - Lists continue on Return (bullets, numbers, tasks). Return on an empty item ends the list.
  - Reading view: rendered markdown, tappable checkboxes, clickable wikilinks (a missing note is created, like in Obsidian), callouts (foldable), tables, code blocks, embedded images and notes (`![[...]]`), frontmatter properties, and a **Linked mentions** (backlinks) section.
  - Quick switcher: fuzzy "go to file", or create a note with the typed name. Full-text search across the vault.
  - Back/forward navigation history. Reopens the last note.
  - Renaming a note updates `[[links]]` that point to it (can be turned off).
  - Images and PDFs can be viewed. Other files can be shared/opened in another app.
- **Home-screen widgets.** Any `*.gitsidian.widget` file in a vault can be a Home Screen widget: a small JavaScript program (same API as [Kondai](https://github.com/ramraj07/kondai)) with pages, charts, canvas drawings, live timers and buttons that open notes. The widget pulls the file straight from GitHub, so a commit from an agent updates it. Live preview in the app. See [`docs/widgets.md`](docs/widgets.md).
- **Sync as batched commits.**
  - Typing saves to disk right away. After you stop editing (default 30s), and whenever the app goes to the background, all changes go up as **one commit** (`vault backup: 2026-11-22 14:03 (3 files)` plus the list of files).
  - Every sync first pulls. Remote changes to files you didn't touch are applied. When both sides edited the same file, a line-based **3-way merge** runs. If the same lines changed on both sides, the remote version wins the original path and your version is kept as `Note (conflict 2026-11-22 1403).md`. Nothing is ever silently lost.
  - The push is fast-forward only. If the branch moved during the sync, it pulls and retries.
  - `.obsidian/` and other hidden files sync too. They're just hidden in the explorer unless you turn them on in Settings.

## How it works

| Piece | File |
|---|---|
| GitHub REST / Git Data API client | `Gitsidian/Sync/GitHubClient.swift` |
| Clone, pull/merge, batched commit (an actor that owns the working copy) | `Gitsidian/Sync/SyncEngine.swift` |
| Local change detection using git blob SHA-1 + an mtime/size cache | `Gitsidian/Sync/GitHash.swift` |
| `.tar.gz` reader (initial clone and big pulls in one request) | `Gitsidian/Sync/TarGz.swift` |
| 3-way line merge | `Gitsidian/Sync/Merge3.swift` |
| Vault state: tree, navigation, file ops, link resolution, auto-sync scheduling | `Gitsidian/Vault/VaultSession.swift` |
| Editor (UITextView + highlighter + keyboard toolbar) | `Gitsidian/Editor/` |
| Reading view (block parser + SwiftUI renderer) | `Gitsidian/Markdown/` |
| Screens | `Gitsidian/Views/` |
| Widget file preview / starter template | `Gitsidian/Widgets/`, `Shared/WidgetTemplate.swift` |
| Widget script runtime (JavaScriptCore → SwiftUI, from Kondai) | `Shared/WidgetRuntime/` |
| App Group cache, deep links, shared Keychain token | `Shared/WidgetShared.swift`, `Shared/Keychain.swift` |
| WidgetKit extension (file picker, GitHub refresh, page buttons) | `GitsidianWidget/` |

Each vault is a plain folder in the app's Application Support directory, plus a `state.json` holding the last synced commit, tree, and path→blob-sha map. Commits are built with the Git Data API (create blobs → create tree on `base_tree` → create commit → fast-forward the ref), so no git binary or libgit2 is needed. Commits are attributed to the token's GitHub user.

## Building

Needs Xcode 16+ and iOS 17+.

1. Open `Gitsidian.xcodeproj`.
2. Under *Signing & Capabilities*, choose your team for both the **Gitsidian** and **GitsidianWidget** targets. If you change the bundle id from `com.gitsidian.app`, keep the widget's as `<app id>.widget`, and if you change the App Group (`group.com.gitsidian.app`), change it in both `Config/*.entitlements` and `AppGroup.identifier` in `Shared/WidgetShared.swift`.
3. Run on your iPhone.

The project uses Xcode 16's synchronized folders, so any file added under `Gitsidian/`, `Shared/` (both targets) or `GitsidianWidget/` is picked up automatically. CI (`.github/workflows/build.yml`) builds for the simulator on every push.

## Token

Create a [fine-grained personal access token](https://github.com/settings/personal-access-tokens/new) with access to the vault repos:

- **Contents: Read and write**
- **Metadata: Read** (added automatically)

The token is stored in the iOS Keychain.

## Not (yet) supported

- Graph view (intentionally out of scope).
- Canvas rendering (`.canvas` opens as JSON text).
- Plugins, and Dataview/Tasks queries (their blocks render as code).
- Git LFS files.
- Repos with more than ~100k files (the GitHub tree API truncates).
