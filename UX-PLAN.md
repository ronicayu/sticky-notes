# Sticky Notes — 10x UX Plan

> **Status: all five phases implemented.** 419 tests, no build warnings, bundle builds.
> Notable find along the way: the preview pane's vertical divider was an `NSBox`,
> whose separator style carries an intrinsic height meant for *horizontal* rules —
> it fought its constraints and silently collapsed the whole quick-switcher to 80pt.
> Every assertion stayed green; only rendering the snapshot caught it.


A phased plan for making the app *feel* 10x better, written for an implementing agent (Opus 5). The feature set is now strong (see `PLAN.md` — all phases shipped); what separates this app from a great one is no longer capability but friction, feedback, and trust. Every item below names the friction it removes and how to verify the fix.

## Ground rules for the implementer

1. The bar for every change: **fewer clicks, calmer screen, never lose the user's trust.** If a change adds chrome or configuration, it's probably wrong.
2. One phase per branch. 362 tests exist and must stay green; pure-logic changes (placement math, toast timing, sort orders) get new tests. Verify visual changes by rendering offscreen (see `NotesPanelSnapshotTests` for the pattern, `SNAPSHOT_DIR` to emit PNGs) and by running the real app with `swift run`.
3. Respect what's already deliberate: fade-on-blur, marker-hiding markdown, the drag-strip-not-body drag, empty-note discard on close. Change behavior only where this plan says to, and keep Reduce Motion / Reduce Transparency handling intact (`Appearance.swift`).
4. Don't add settings to avoid making a decision. A new preference is a last resort and needs a sentence of justification in the commit message.

---

## Phase 1 — Capture flow: from hotkey to typing, zero thought

The founding promise is instant capture. The remaining friction is all in the seconds after `⌘⇧S`.

### 1.1 Fix note placement (this is a live bug, not a preference)
`Note.makeNew()` (`Note.swift:166`) places new notes at a **random position inside a hardcoded 1440×900 rect** — on other screen sizes and multi-monitor setups notes land wherever, sometimes behind the dock, and randomness means the user hunts for the note they just made.

- New notes spawn on **the screen containing the mouse pointer**, at a stable anchor: offset ~24pt down-right from the last note created this session, restarting the cascade when it would leave the visible frame (reuse `WindowArrangement.cascade` math). First note of a session: centered-upper-third, like the quick switcher.
- Placement becomes a pure function (`NotePlacement.next(previous:screen:)`) with tests: stays inside `visibleFrame`, cascades, restarts, handles a tiny screen.
- `makeNew()` loses its fake screen entirely — the AppDelegate passes real geometry in.

### 1.2 Abandoned-capture cleanup
An empty note is discarded when the user clicks its × (`closeNote`), but a hotkey misfire leaves an empty note littering the desk forever.

- A note that is still empty (no title, no content, never edited) when its window **loses focus** is quietly discarded, window and all. A note the user typed into is never touched. Test at the store level; verify the never-typed vs typed distinction carefully — deleting a note someone intended to keep is the worst bug this plan could introduce, so gate on "zero edits ever," not "empty now."

### 1.3 Same-chord dismiss
`⌘⇧S` while the just-created, still-empty note is focused should close it (same muscle-memory toggle the quick switcher already has). Second press = "never mind."

### 1.4 Create from the quick switcher (Notational Velocity's one great idea)
Today a no-match search dead-ends at "No matches for 'x'". That moment *is* a capture intent.

- When the query matches nothing, `↩` creates a note titled with the query and opens it, caret in the body. The status line advertises it: `↩ to create "buy milk"`.
- When there are matches, `⌘↩` (currently unused… it opens collapsed — reassign that to `⌥↩`) creates rather than opens, so a near-match never blocks a new note.
- This merges capture and search into one reflex: `⌘⇧F`, type, `↩` — whether the note exists or not. Tests: rank/create decision logic; switcher returns a `.create(title:)` selection variant.

---

## Phase 2 — Trust: nothing is ever more than one keystroke from undone

### 2.1 Undo toast for archive
Archiving via the trash button or `⌘⌫` makes the note vanish with no recourse short of opening the panel and finding it. Add a small floating toast (bottom-center of the note's screen, auto-dismissing after ~6s): **"Archived 'Groceries' — ⌘Z to undo"**, where ⌘Z (or clicking the toast) restores the note to its exact previous frame. One toast at a time; a second archive replaces it. Reduce Motion: no slide, just appear/disappear.

- Build it as `ToastController` with a testable model (message, action, expiry). The restore path must reuse `NoteStore.restore` + the saved frame, not a parallel mechanism.

### 2.2 The same toast for label-hide and hide-all
"Hide All" and hiding a label make windows vanish identically to a bug. Reuse the toast: "Hidden 3 #work notes — ⌘Z to show". No new persistence; it just calls the existing toggles back.

### 2.3 Deletion honesty
The delete confirmation still says "permanently" (`NotesPanelController.deleteSelected`) but Phase 5 made deletion a 30-day trash move. Reword: **"Move to Trash?" / "Notes stay in Trash for 30 days."** Scary copy that's no longer true erodes trust in the copy that is.

---

## Phase 3 — Direct manipulation: the note under your hands

### 3.1 Move from anywhere
Dragging requires hitting the 22px top strip (18px collapsed) — precision work for the most common physical action. Add **⌘-drag anywhere on the note body** to move the window (the body currently ignores ⌘-clicks except on links — route non-link ⌘-drags to `window.performDrag`). The strip keeps working; ⌘-drag is the power path. Snapping and the ⌥ opt-out apply identically.

### 3.2 Snap feedback
Snapping currently teleports the note on drop with no acknowledgment. Flash a 1px accent line along the snapped edge for ~300ms (skip under Reduce Motion). Cheap, and it teaches the feature by showing it.

### 3.3 Resize affordance
Borderless windows give no hint they resize. Show a subtle drag-dots glyph in the bottom-right corner while the pointer is over the note (same hover treatment as the chrome buttons). Purely visual — resizing already works.

### 3.4 Collapsed-note ergonomics
18px is a hostile click target and the only affordance is knowing to double-click. Make a **single click on a collapsed note's bar expand it** (drag still drags — distinguish click from drag by movement threshold, which `NoteDragZone.mouseDown` can do since it owns the event). Double-click keeps toggling both ways. Raise collapsed height to 22px to match the expanded strip; migrate nothing — it's display-only.

### 3.5 Delete dead code while in there
`ColorPickerBar` in `NoteChrome.swift` is never constructed. Remove it.

---

## Phase 4 — Reading and writing comfort

### 4.1 Text size
13pt fixed body text. Add `⌘+` / `⌘-` / `⌘0` per the platform convention, global (all notes), persisted in `Settings`, range 11–18pt. `MarkdownStyler.baseFontSize` becomes a settings-backed value; heading sizes scale from it. This is the one place a preference is justified: it's an accessibility need, and the OS convention already exists.

### 4.2 Editor breathing room
Audit and fix in one pass, with before/after snapshots: text inset (currently cramped against the left edge under the checkbox gutter), line spacing for multi-line notes (set `paragraphSpacing`/`lineHeightMultiple` ~1.15 in the styler), bottom padding so the last line isn't flush with the window edge.

### 4.3 Quick-switcher preview pane
For notes longer than a screenful, the excerpt line isn't enough to pick between similar results. Add a right-hand preview (rendered read-only markdown, reusing `MarkdownStyler.apply(to:)` on a storage) that follows the selection. Layout: list narrows to ~55%, preview fills the rest; hidden when the window is narrow. Snapshot-test both states.

---

## Phase 5 — Calm the periphery

### 5.1 Menu bar diet
The status menu has regrown to ~12 items. Regroup: capture actions (New, New from Clipboard, Find) → then a **Notes** submenu (Panel, Hide All, Show Labels, Arrange) → Daily Note → Settings/Storage/Quit. Top level back to ~7 rows. The `menuWillOpen` state logic moves with the items.

### 5.2 Hotkey conflict detection
`⌘⇧S` collides with "Save As" muscle memory and `⌘⇧F` with several apps' find-in-project; users will rebind, and `KeyboardShortcuts` already handles the recording. What's missing is discovery: when a registered hotkey fires but the app was already frontmost with a text field focused (i.e., the user probably meant the app's own shortcut), do nothing different — but in Settings, show each recorder's current binding beside a note when it's known-contested (a static list: `⌘⇧S`, `⌘⇧F`, `⌘⇧L`, `⌘⇧V` conflicts with Xcode/Chrome/Finder equivalents). Informational only; no behavior change.

### 5.3 First-run permission guidance
The welcome note explains hotkeys, but if Accessibility/Input Monitoring permission is missing, hotkeys silently don't fire — the app looks broken in its first minute. On first launch, after creating the welcome note, check `AXIsProcessTrusted()`; if false, append a checklist line to the welcome note pointing at the exact System Settings pane, and show the storage-warning-style menu bar hint until it's granted. Remove the hint (not the note line) once trusted.

---

## Sequencing and sizing

| Phase | Size | Rationale for order |
|-------|------|---------------------|
| 1 Capture flow | M | The founding promise; 1.1 is a live bug |
| 2 Trust / undo | M | Makes every other destructive surface safe to use boldly |
| 3 Direct manipulation | M | Daily-feel wins, independent of 1–2 |
| 4 Reading & writing | M | Comfort compounds; 4.1 is accessibility |
| 5 Periphery | S | Cleanup; 5.3 prevents the worst first-run outcome |

## Explicitly out of scope

- An Exposé-style overview of all notes (fun, big, unproven need — revisit after Phase 3 ships).
- Merging the notes panel and quick switcher (they serve browse vs. jump; unify only if 4.3 makes the panel feel redundant in practice).
- Sounds, custom cursors, onboarding tours, or any new windows beyond the toast.

## Definition of done, per phase

Tests green, no new build warnings, snapshot PNGs attached for anything visual, `swift run` sanity pass, README updated only where behavior visible to users changed, and a commit message that names the friction removed rather than the code changed.
