# Sticky Notes — 10x Plan

A phased implementation plan for making this app dramatically better. Each phase is independently shippable and ordered so that foundations land before features that depend on them.

## Status

**All phases implemented.** 362 tests, no build warnings, release bundle builds.

| Phase | State |
|-------|-------|
| 0 Foundations | ✅ test target + CI, note cache, storage-error surfacing |
| 1 Search | ✅ quick switcher, panel search/filter/sort, label show-hide |
| 2 Editor | ✅ links, wiki links, attachments, editor shortcuts, task counts |
| 3 Capture | ✅ clipboard hotkey, Services entry, `stickynotes://` scheme |
| 4 Windows | ✅ dark mode, edge snapping, arrange, per-note float level |
| 5 Data safety | ✅ conflict merging, recoverable trash with a panel tab |
| 6 Distribution | ✅ welcome note, accessibility, signing + notarization in the build script |

Bugs found and fixed along the way, each with a regression test:

- Nested emphasis (`***x***`) rendered italic-only — `Emphasis` replaced the font `Strong` had set instead of merging traits.
- Saving the Nth note into a vault re-read the other N-1 looking for an id that wasn't there. 500 saves took ~30s; now ~0.5s.
- Archive and restore silently did nothing when the storage path went through a symlink — `contentsOfDirectory` resolves symlinks, so directory paths compared as strings never matched.
- iCloud conflict versions were ignored entirely, so whatever a second Mac wrote was discarded on the next read.

## Deliberately not done

- **Inline image rendering.** Pasting an image saves it and inserts a Markdown reference, but the image isn't drawn in the editor. The note body *is* the saved file, and `NSTextView` only draws attachments at a real attachment character — rendering inline means the editor's string stops being the saved content, which is a change to the save path and deserves its own pass.
- **Auto-update.** Notarization is wired up; a Sparkle-style update feed is not. It needs a hosting decision first.
- **The deferred ideas below** (templates, reminders, note graph, iOS companion, AI assist).

## Context: what exists today

macOS menu-bar app (~5,700 lines, AppKit + SwiftPM, deps: `KeyboardShortcuts`, `swift-markdown`). Current capabilities:

- Floating per-note `NSPanel` windows across all Spaces, collapse/expand, 7 pastel colors, auto-fade on blur (`NoteWindowController.swift`, `NoteChrome.swift`)
- Live Obsidian-style markdown preview with marker hiding (`MarkdownStyler.swift`), interactive checkboxes (`CheckboxAttachment.swift`)
- Storage: JSON in Application Support / iCloud Drive, or `.md` + YAML frontmatter in an Obsidian vault (`NoteStore.swift`, `MarkdownFile.swift`); FSEvents watcher reconciles external edits (`FileWatcher.swift`, `AppDelegate.reconcileOpenWindows`)
- Labels with normalization + autocomplete (`Note.swift`, `LabelViews.swift`)
- Daily note that follows an Obsidian daily-notes pattern and rolls over at midnight/wake (`DailyNote.swift`, `DailyNoteWindowController.swift`)
- Notes panel listing active + archived notes (`NotesPanelController.swift`)
- Settings window (uncommitted, in progress): hotkey recorders, default color, storage mode, vault + daily-note config (`SettingsWindowController.swift`)

**Constraints to preserve:** local-first plain-file storage, no heavy dependencies, no Electron/SwiftUI rewrite, AppKit idioms, SwiftPM build (`swift run` for dev, `scripts/build-app.sh` for the bundle). Files must stay hand-editable and Obsidian-compatible in markdown mode.

## Engineering ground rules for the implementer

1. One phase per branch/PR. Run `swift build` after every change; verify behavior with `swift run` before declaring done.
2. Don't regress the recent hard-won fixes (see git log): external-deletion no-resurrect, frame clamping to visible screens, daily-note rollover, collapsed-title visibility.
3. New logic goes in testable, UI-free types wherever possible. Every phase adds tests for what it touches.
4. Finish and commit the in-progress Settings work (currently uncommitted) before starting Phase 1.

---

## Phase 0 — Foundations: tests, CI, performance (do first)

The app has **zero tests** and every feature below touches parsing or storage. This phase makes the rest safe.

### 0.1 Test target + CI
- Add a `StickyNotesTests` target to `Package.swift` (this requires splitting app code into a library target that the executable and tests both import — mechanical but touches `Package.swift` and `main.swift`).
- Priority test coverage, all pure logic that exists today:
  - `MarkdownFile` parse/serialize round-trip, including quoted titles, missing frontmatter keys, hand-mangled YAML
  - `NoteStore` markdown/JSON round-trip, archive/restore/delete, the no-resurrect guard (`knownIds`), `reconfigure` migration
  - `NoteLabel.normalize`, `parseLabelsList` tolerance cases
  - `DailyNote` filename-pattern resolution and rollover date math
- GitHub Actions workflow: `swift build && swift test` on macOS runner, on push + PR.

### 0.2 NoteStore caching
Today `loadActive()`/`loadArchived()` re-read every file from disk on each call, and `allLabels()` reads *everything twice*. The notes panel, label menus, and reconcile loop all call these repeatedly.
- Add an in-memory cache of decoded notes inside `NoteStore`, invalidated by the `FileWatcher` callback (per-directory, not per-file — FSEvents granularity is coarse; a full directory rescan on invalidation is fine, the win is skipping rescans when nothing changed).
- Keep the public API identical. Acceptance: notes panel opens instantly with 500 notes on disk (generate fixtures in a test).

### 0.3 Error surfacing
Storage code is `try?` throughout — a full disk or permissions error today means silent data loss. Add a minimal failure path: when a write fails, retry once, then show a sticky menu-bar warning state (⚠️ icon + menu item naming the failing file). No new UI beyond that.

---

## Phase 1 — Find anything instantly (biggest single win)

A sticky-notes app becomes 10x more useful the moment old notes stay retrievable. Today retrieval = scrolling a flat panel list.

### 1.1 Quick-switcher palette
- New global hotkey (default `⌘⇧F`, recorder in Settings alongside the existing three in `SettingsWindowController`).
- Spotlight-style floating panel: type → fuzzy match over title, content, and labels of active + archived notes. Rank: title hits > label hits > body hits; recency as tiebreak.
- `↩` opens/focuses the note (restoring from archive if needed — reuse `NoteStore.restore`), `⌘↩` opens it collapsed, `esc` dismisses.
- Implementation: new `QuickSwitcherController` (NSPanel + NSTextField + NSTableView, no new deps). Fuzzy matcher is a pure function → unit tests.

### 1.2 Notes panel upgrades
`NotesPanelController` gains:
- A search field (same matcher as 1.1) and a label filter dropdown.
- Sort control: updated / created / title / color.
- Full keyboard navigation: arrows + `↩` to open, `⌘⌫` to archive.

### 1.3 Label-based show/hide
"Hide all" already exists. Add per-label visibility: menu-bar submenu listing all labels (from the cached `allLabels()`), checkable, so the user can e.g. show only `#work` notes during the day. Persist the filter in `Settings`.

---

## Phase 2 — Editor: from note-taking to thinking surface

All in `MarkdownStyler.swift` / `NoteWindowController.swift` unless noted.

### 2.1 Links
- Auto-detect URLs and render `[text](url)` as clickable links (`.link` attribute; `⌘`-click or click-when-unfocused opens, plain click inside the editor places the cursor — match Obsidian behavior).
- Paste a URL over selected text → wrap selection as a markdown link.
- In markdown-vault mode, render `[[wiki links]]`; clicking one opens the matching note by title if it's one of ours, else hands off to Obsidian via `obsidian://open`.

### 2.2 Images
- Paste an image → save to an `attachments/` directory next to the notes (or the vault's configured attachment folder in markdown mode), insert `![](path)`, render inline scaled-to-width via `NSTextAttachment`.
- Acceptance: paste screenshot, quit, relaunch — image still renders; the `.md` file references a real file Obsidian also renders.

### 2.3 Task affordances
- Checkboxes already exist. Add: collapsed notes and panel rows show a `3/7` done-count badge when the note contains checkboxes.
- `⌘L` toggles the current line's checkbox; `⌘⇧L` conflicts with the panel hotkey, so use `⌘⏎` as toggle-checkbox-on-current-line (Things-style).

### 2.4 Editing quality-of-life
- List continuation on `↩` (new bullet/number/checkbox), `⇥`/`⇧⇥` indent/outdent list items.
- Smart markdown shortcuts: `⌘B`/`⌘I`/`⌘E` wrap selection in `**`/`*`/`` ` ``.

---

## Phase 3 — Capture from anywhere

Capture speed is the app's founding premise; extend it beyond "empty note".

### 3.1 Capture with content
- New hotkey "New note from clipboard": creates a note pre-filled with the pasteboard (text or image once 2.2 lands).
- macOS Services entry ("New Sticky Note from Selection") so any app's right-click menu can send selected text in. Services need `NSServices` in Info.plist — `scripts/build-app.sh` generates the bundle, so add it there; document that Services don't work under bare `swift run`.

### 3.2 URL scheme for automation
- Register `stickynotes://` (Info.plist + `NSAppleEventManager` handler in `AppDelegate`): `stickynotes://new?text=...&color=...&labels=...`, `stickynotes://search?q=...`, `stickynotes://daily`.
- This unlocks Raycast, Alfred, and Shortcuts integration for free. Document the scheme in the README.

---

## Phase 4 — Windows that behave like a desk, not confetti

### 4.1 Arrangement
- Edge snapping while dragging: notes snap to screen edges and to other notes' edges (8px threshold, suppress with `⌥`). Implement in `NoteWindow`/`NoteWindowController` drag handling.
- Menu-bar "Arrange Notes": cascade or grid-pack all visible notes on the current screen, animated. One command, huge tidiness payoff.

### 4.2 Float modes
- Per-note float level: **Float above all** (today's behavior) vs **Stick to desktop** (classic Stickies — visible with desktop, behind app windows: `.desktopIcon`-adjacent window level). Toggle in the note's chrome menu; persist in frontmatter (`floatLevel` key with a decode fallback, following the existing optional-field pattern in `Note.init(from:)`).

### 4.3 Dark mode
Colors are fixed light pastels. Add dark-variant `bodyHex`/`headerHex` per `NoteColor`, switch with the system appearance (`NSApp.effectiveAppearance` observation). Text colors in `MarkdownStyler` must follow. Files on disk unchanged — same color names.

---

## Phase 5 — Data safety & sync robustness

### 5.1 iCloud conflict handling
Current model is last-writer-wins; iCloud Drive can produce `NSFileVersion` conflicts that are silently ignored. On watcher events, check `NSFileVersion.unresolvedConflictVersionsOfItem`; resolve by keeping the newest and appending the loser's body under a `--- conflicted copy (date) ---` divider. Never discard content.

### 5.2 Recoverable delete
- `archive/` already acts as a trash. Add: "Deleted forever" actually moves to a `.trash/` folder purged after 30 days, so panel-delete becomes recoverable.

---

## Phase 6 — Distribution & polish

### 6.1 Real releases *(needs a decision from Ronica: requires a $99 Apple Developer account)*
- Developer ID signing + notarization in `scripts/build-app.sh`, then Sparkle (or a minimal in-house update check against GitHub Releases — prefer minimal, matching the no-deps ethos) and a Homebrew cask. Kills the "Open Anyway" friction that loses most would-be users.

### 6.2 First-run experience
- On first launch: one welcome note (a real note, pre-filled with the hotkeys and a checkbox demo) instead of an empty screen. Delete-able like any note.

### 6.3 Accessibility pass
- VoiceOver labels on chrome buttons, panel rows, settings controls; respect Reduce Transparency/Motion for the fade animations.

---

## Deferred ideas (revisit after Phase 6)

- Note templates; reminders parsed from natural-language dates; note-to-note linking graph; iOS/iPadOS companion; optional AI assist (summarize/extract tasks). None of these earn a slot before retrieval, capture, and data safety are done.

## Suggested order & sizing

| Phase | Size | Why this order |
|-------|------|----------------|
| 0 Foundations | M | Everything else edits parsing/storage; tests + cache first |
| 1 Search | M | Single biggest utility jump |
| 2 Editor | L | Links + images make notes rich; builds on 0's tests |
| 3 Capture | S | Small code, big workflow win; URL scheme unlocks power users |
| 4 Windows | M | Visible daily-feel improvement |
| 5 Data safety | M | Needed before promoting sync harder |
| 6 Distribution | S–M | Turns a personal tool into an installable product |
