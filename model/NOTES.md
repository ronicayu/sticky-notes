# Model notes

Code modelled: commit `cbbec6621a3c81c6a5cd2bfa53618237bd35e156` (branch `masterpiece-plan`).
The working tree was clean at that commit when the models were written, so the line numbers below
are the same as `git show cbbec66:<path>`.

Two specs:

- `NotePersistence.tla`: model (a), one sticky note in Obsidian vault mode, vault inside iCloud
  Drive. View: `note-view.mjs`.
- `DailyRollover.tla`: model (b), today's daily note on two Macs across one midnight. View:
  `daily-view.mjs`.

Outputs of every config are in `out/<config>/` (`report.md`, `chart.mmd`, `tlc.out`).

## Abstractions

- A body is a set of edit tokens. Merging text is set union; a "Conflicted copy" block is the
  token `D`. Model (a) also records which tokens were non-append edits (backspace, mid-line
  insert): an older version is a substring of a newer one only when every token added since was an
  append. That is the test `ConflictResolver.merge` uses (`winningBody.contains(body)`).
- Model (a) keeps one note. A second note adds nothing: notes do not share state except the store's
  caches, which the model does not need.
- The Markdown round trip is exact for the body and the title: `MarkdownFile.serialize` writes
  `---\n<frontmatter>---\n\n<body>`, `parse` drops exactly one empty line after the closing `---`,
  and the title goes through `forceQuote` / `unescapeDoubleQuoted`. So an echo of our own write
  reads back equal, and the model does not model the round trip. Swift `String ==` also compares
  canonically equivalent Unicode as equal.
- Titles are not modelled (both models treat the title as empty). Labels are not modelled.
- Time: "30 days pass" is one step (`MonthPasses`). The 0.5 s / 0.4 s debounce, the 0.25 s watcher
  debounce and the 5 s conflict-sweep rate limit are interleavings, not clocks.
- `PROMPT_WATCHER` (model (a)) removes the window between an outside write landing and the watcher
  reporting it. Only the regress configs use it, so that the blind-write break (R1 of the plan) does
  not hide the fixed bug each regress config must show.

## Model (a) actions → code

| Action | Code (cbbec66) |
| --- | --- |
| `Init` | AppDelegate.swift:540-576 `makeNote` → `noteStore.save` (line 562), not `persist()`, so `lastPersistedContent` is nil; the store write echoes through the watcher later |
| `Type` | NoteWindowController.swift:815-825 `textDidChange` → `scheduleSave` 1612-1627 |
| `SaveFires` | NoteWindowController.swift:1612-1627 work item → `mergePendingExternalNote` 1347-1371 → `persist` 1634-1639 → NoteStore.swift:103-137 `save` |
| `SwitchAway` | NoteWindowController.swift:741-760 `windowDidResignKey` (abandoned-capture discard 744-750 via 93-100; merge + persist 754-757) |
| `ClickIntoText`, `GrabTitleBar` | first responder changes; `handleStoreChange` reads `isKeyWindow` and `firstResponder` (1324-1331) |
| `CloseNote` | NoteWindowController.swift:538-563 `closeNote` → NoteStore.swift:161-168 `discardActive` or 153-159 `archive` |
| `Quit` | AppDelegate.swift:44-54 `applicationShouldTerminate` → `flushPendingSave` NoteWindowController.swift:1644-1650 |
| `Relaunch` | NoteStore.swift:89-101 `init` → `purgeExpiredTrash` 245-266; AppDelegate `restoreActiveNotes` |
| `Restore`, `DeleteForever`, `RestoreFromTrash` | NoteStore.swift:170-182, 197-211 (+ `stampDeletionDate` 235-240), 224-230 |
| `PanelArchive` | NotesPanelController.swift:385-388 `archiveSelectedRow` → `store.archive` directly |
| `WatcherDelivers` / `Deliver` | FileWatcher.swift:67-78 → NoteStore.swift:365-375 → `NoteStore.didChange` → NoteWindowController.swift:1302-1333 `handleStoreChange` and AppDelegate.swift:118-137 `reconcileOpenWindows` → `closeAfterExternalDeletion` NoteWindowController.swift:1657-1662 or `presentWindow` |
| `ConflictSweep` | NoteStore.swift:443-501 `resolveConflictsIfDue` / `resolveConflict` → ConflictResolver.swift:15-40 `merge`; posts `didChange` synchronously (463), so the window sees the merge in the same step |
| `ExternalEdit` | Obsidian or the other Mac writes the file |
| `ExternalConflict` | the other Mac edited an older copy; iCloud keeps an `NSFileVersion` conflict |
| `ICloudSelfConflict` | hypothesis 1: iCloud keeps an older write of this Mac as a conflict version (no `NSFileCoordinator` anywhere in the code) |
| `ObsidianStaleRewrite` | Obsidian (note open there, or a lint/format plugin) writes back an older copy of our text |
| `ExternalArchive`, `OtherMacDiscardsEmpty` | the other Mac runs `store.archive` / `discardActive` on its copy |
| `FileVanishes`, `FileReturns` | the file is briefly unreadable or missing from `contentsOfDirectory` (NoteStore.swift:503-521, `read` 523-532 returns nil) |

## Model (b) actions → code

| Action | Code (cbbec66) |
| --- | --- |
| `Midnight` | wall clock |
| `Rollover` | DailyNoteWindowController.swift:514-523 `handleMidnight`, from the timer 499-512, `handleWake` 549-552 or `rolloverIfNeeded` 530-534 in `show` |
| `Load` (inside `Rollover`, `UnavailableRetry`) | DailyNoteWindowController.swift:270-313 `loadCurrentFile` (heal 276, read 285-290, unavailable 298-307, `seedBuffer` 327-333) |
| `UnavailableRetry` | DailyNoteWindowController.swift:409-418 |
| `Type` | DailyNoteWindowController.swift:755-759 → `scheduleSave` 378-383; the text view has no `isEditable = false` anywhere, so the placeholder takes typing |
| `SaveFires` / `SaveNow` | DailyNoteWindowController.swift:441-461 `saveNow` (merge 445, skip when `body == lastLoadedContent` 447, write 456) |
| `SwitchAway` | DailyNoteWindowController.swift:746-751 `windowDidResignKey` |
| `PersonOpensToday` | DailyNoteWindowController.swift:607-617 `show(userInitiated: true)` → `createTodaysFileIfMissing` 627-645; AppDelegate.swift:685-696 |
| `WatcherDelivers` | DailyNoteWindowController.swift:336-362 `reloadIfExternallyChanged` (heal 340, defer only when key and first responder 353-358, else apply 360-361) |
| `Heal` | DailyNote.swift:190-231 `healDuplicates`, DailyNoteWindowController.swift:471-481 |
| `Upload`, `Download`, `Evict`, `DupGone` | iCloud Drive. Two independent creates of one path become `<name> 2.md` (cbbec66 message); an edit on a stale copy becomes an `NSFileVersion` conflict; nothing in the daily-note code reads `NSFileVersion` (grep) |

## Values merged

- Model (a): one outside token `x1`; its shape (append or not) only matters inside conflict merges,
  so `ExternalEdit` always appends. Two local tokens, because hypothesis 1 needs a save, then a
  non-append edit, then a save.
- Model (b): Mac B's window is only clicked when Mac B's person types (`ALLOW_B_TYPES`), which keeps
  the configs under 100k states. Only Mac A types before midnight.
- Model (b): all day-2 edits are appends, so `mergeBodies` containment is subset.

## Expected versus observed (written up after the runs)

| Config | Expected from reading the code | Observed |
| --- | --- | --- |
| owner-alone (empty new note, no other writer) | holds: the creation echo is empty and `ConflictResolver.merge` skips empty bodies | held |
| owner-h1 | `NoSpuriousConflictBlock` breaks: save, non-append edit, save, iCloud keeps the first save, sweep appends it | broke on exactly that path |
| owner-h2-prefilled | breaks: non-append edit to captured text inside the echo window | broke |
| a-edits round 1 | `TypedTextKept` by blind write (R1); stale `lastPersistedContent` breaks `WindowMatchesDisk` | `TypedTextKept` broke first by the empty-note discard (surprise, confirmed in code); blind write showed in round 2; `NoSpuriousConflictBlock` broke by an outside append while the caret sat in the note (surprise, confirmed in code); stale mark as predicted |
| a-conflicts r1 | spurious block from a self-conflict | the shortest is a one-sided block on an empty note (same rule, same fix) |
| a-removal | reconcile drops unsaved typing | the other Mac's empty discard came first; then save skipped when the note left the folder; then reconcile |
| b-create r1 | R4 (apply over unsaved while the title bar is grabbed) | as predicted; R5 in round 2; unmerged daily `NSFileVersion` conflict in round 3 (not in the plan) |
| b-midnight r1 | R6 (typing into the placeholder) | as predicted |
| every regress-*.cfg | breaks | all break |

## Model artefacts found and fixed during the work

1. The conflict sweep first set "unseen" and let the window learn of the merge later. In the code
   `resolveConflicts` posts `didChange` synchronously (NoteStore.swift:463), so the window sees it
   at once. Fixed with `Deliver`, after a trace closed the note between the sweep and the watcher.
2. The proposed fix for the empty-note discard first left a deferred edit stuck when the discard was
   refused. Fixed so a refused discard falls through to the normal resign-key branch (as the code's
   other branch does).
3. The proposed fix for the blind write also fixes BUGFIX-PLAN 0.4 and R3, so their regress configs
   showed nothing. The regress configs now keep the blind write as in the code and use
   `PROMPT_WATCHER` instead.

## How to rerun

```sh
cd /Users/ronica/projects/sticky-notes/model
R=/Users/ronica/.claude/plugins/cache/ronica-skills/statechart/0.3.0/skills/statechart/scripts/statechart
export TLA2TOOLS=$HOME/.cache/statechart/tla2tools.jar JAVA=/opt/homebrew/opt/openjdk/bin/java
$R NotePersistence.tla --config owner-h1.cfg --view note-view.mjs --out out-new/owner-h1
$R DailyRollover.tla --config b-create.cfg --view daily-view.mjs --out out-new/b-create
```

Use a new `--out` folder each run. `NotePersistence.cfg` and `DailyRollover.cfg` are templates
with every actor on (about 870k and 400k states); run the split configs instead.
