# Bug Fix Plan — 32 reviewed bugs fixed, plus 16 the fix round itself surfaced

*(of those 16: 12 were regressions these fixes introduced, caught before landing; 4 were
pre-existing bugs the second review turned up.)*

Findings from a full-codebase review (4 parallel reviews: data/persistence, note windows,
app controllers, markdown/text), then fixed in place, then reviewed again for defects the
fixes themselves introduced (see Round 2 — it found a critical one). Baseline was 421 tests
passing; the suite is now **440 passing, 0 failures**, and the release build is clean.

Every fix below is landed. Where a fix had a matching regression test, the test was verified
to *fail* against the old code before being kept — noted as **guarded** with the test name.

---

## Phase 0 — Data loss

**0.1 Quitting dropped pending edits** — `NoteWindowController` debounced saves 0.5s and the
daily note 0.4s, and there was no `applicationShouldTerminate` anywhere, so ⌘Q mid-sentence
lost everything typed since the last pause.
*Fixed:* `flushPendingSave()` on both controller types; `applicationShouldTerminate` drains
every open window controller plus the daily note, then returns `.terminateNow`.

**0.2 Trash purge destroyed recently-deleted notes** — retention was measured from
`contentModificationDate`, but moving a file into `.trash/` preserves it, so a note last
edited 31 days ago was purged the moment it was deleted.
*Fixed:* the deletion date is stamped on the file as it enters the trash, and purge now keys
on `addedToDirectoryDate` with the stamped date as fallback.
**Guarded:** `testANoteDeletedTodaySurvivesEvenIfItWasEditedLongAgo`.

**0.3 Archiving discarded the last ≤0.5s of typing** — `closeNote` cancelled the pending save,
then called `store.archive`, which only *moves* the file and never writes the in-memory note.
*Fixed:* content and frame are saved synchronously before the archive move.

**0.4 External edits were silently clobbered** — both editors parked an incoming external edit
while the user typed but left the armed local save running; the save overwrote the external
text, and the parked copy was then dropped on blur.
*Fixed:* added `ConflictResolver.mergeBodies` and merged (never dropped) the deferred edit
before every write — debounced save, terminate flush, and blur.
**Guarded:** six `mergeBodies` cases in `ConflictResolverTests`.

**0.5 Unreadable daily-note file was overwritten with the template** — a failed read was
indistinguishable from "no file", so an iCloud placeholder got the template written over it.
*Fixed:* `fileExists` is checked separately; exists-but-unreadable suspends saving, requests
the iCloud download, and waits for the watcher.

## Phase 1 — Broken features

**1.1 Quick switcher: Return and ↑/↓ did nothing** — the palette overrode `keyDown` on the
search field, which the field editor never calls while editing.
*Fixed:* implemented `control(_:textView:doCommandBy:)`.
**Guarded:** `testReturnOpensTheHighlightedResult`, `testArrowKeysMoveTheSelection`,
`testUnrelatedCommandsAreNotSwallowed`.

**1.2 Attachment links were broken two ways** — generated names contained a space, which stops
CommonMark seeing a link at all; and clicked relative links reached `NSWorkspace.open` as
schemeless URLs it can't open, so every non-image attachment was write-only.
*Fixed:* timestamp format no longer contains a space, link destinations are percent-encoded
(labels stay readable), and an `attachmentResolver` hook resolves relative paths at click time.
**Guarded:** three tests in `AttachmentsTests`.

**1.3 "Hide Today's Daily Note" didn't stick** — the menu path called `orderOut` without
persisting visibility, so the next keystroke in any note re-showed it.
*Fixed:* menu and window-button paths share `hide()`, which flushes, hides, and persists.

**1.4 Emoji in link text visually deleted characters** — marker offsets were measured in
Characters but applied as UTF-16 offsets.
*Fixed:* `text.utf16.distance`. **Guarded:** two tests in `MarkdownLinkTests`.

## Phase 2 — Wrong behavior

**2.1** New note created while notes were hidden was immediately hidden again —
`toggleHideAll` no-ops with no windows. *Fixed:* `makeNote` clears `notesHidden` directly.

**2.2** `%2B` in capture URLs became a space (`text=C%2B%2B` → "C  "). *Fixed:* `+`→`%20`
substitution now happens on the raw query, before percent-decoding.

**2.3** iCloud conflicts were only merged at launch. *Fixed:* the watcher sweeps too,
rate-limited to once every 5s since it fires on our own saves.

**2.4** A save was dropped when an external rename made the cached path stale while the
directory index still vouched for it. *Fixed:* one fresh rescan before concluding deletion.

**2.5** Double-clicking a collapsed note expanded then instantly re-collapsed it.
*Fixed:* a click sequence that already acted doesn't toggle again.

**2.6** External reload left a stale undo stack pointing at discarded ranges.
*Fixed:* `undoManager?.removeAllActions()` after applying external content, both controllers.

**2.7** The abandoned-capture sweep deleted notes the user had deliberately customized.
*Fixed:* picking a color, adding a label, or setting float level marks the note as touched.

**2.8** Three `MarkdownFile` parser traps: unterminated frontmatter consumed the whole
document (and the next save wrote that emptiness back), a newline in a title corrupted the
record, and CRLF files never matched the `---` separator.
*Fixed:* all three. **Guarded:** three tests in `MarkdownFileTests` (one pre-existing test that
pinned the old unterminated-frontmatter behavior was deliberately updated).

**2.8b** The same report noted a fourth trap I initially missed: a vault file carrying no
`id:` — a note written in Obsidian and dropped into the folder — got a *fresh random UUID on
every load*, so each store change made the old note look deleted and a new one created, tearing
down and rebuilding its window.
*Fixed:* an id-less file now derives a stable id from its path.
**Guarded:** `testAVaultFileWithoutAnIdKeepsTheSameIdentityAcrossLoads`.

**2.9** Dark mode: chrome buttons, footer date, and label chips were fixed black on dark paper.
*Fixed:* routed through new appearance-aware inks, repainted on theme flip.
**Guarded:** `testChromeInkFlipsWithTheAppearance`.

## Phase 3 — Polish

| # | Bug | Fix |
|---|-----|-----|
| 3.1 | Menu titles hardcoded default chords, wrong after rebinding | Titles carry no chord text; `setShortcut(for:)` renders the live binding. Hotkeys are suspended while a menu is open so the chord can't fire twice |
| 3.2 | Switching into vault mode didn't restore a visible daily note | `restoreDailyNoteIfNeeded()` when no controller exists yet |
| 3.3 | `lastNewNoteFrame` never reset, so the cascade never returned to the top | Reset when the last window closes |
| 3.4 | Permanent "Hotkeys need Accessibility permission" warning | Removed — the library registers Carbon hotkeys, which never needed that permission |
| 3.5 | Launch-at-login checkbox lied when `SMAppService` returned `.requiresApproval` | Status re-checked after `register()`; offers to open Login Items |
| 3.6 | "Per-machine" daily-note state lived in the synced vault, so two Macs fought | Moved to Application Support, with one-time migration of the existing file |
| 3.7 | Checkbox regex `\s` matched a newline, hiding user text behind a phantom checkbox | `[ \t]` in both positions |
| 3.8 | Styler and editor disagreed about tab-separated checkboxes → double-prefixing | Grammars aligned. **Guarded:** two tests in `MarkdownEditingTests` |
| 3.9 | Expanding near the bottom edge pushed the body offscreen; no clamp on screen change | Clamp after expand and on `windowDidChangeScreen` |
| 3.10 | Collapsed-title checkbox count went stale after an external content-only edit | `refreshCollapsedTitle()` unconditionally |
| 3.11 | Sync-presented notes stayed at 70% opacity | `refreshAlpha()` after ordering the window in |
| 3.12 | Full-document reparse per keystroke | See below — this was a real bug, not just a limitation |

### 3.12 in detail

Measured before deciding: styling cost was **10.7ms at 2.4KB, 85.9ms at 12KB, and 1013ms at
50KB** — superlinear, i.e. one full second per keystroke on a large imported vault note.

Cause: `LineOffsetTable.utf16Offset` resolved each position by walking UTF-8 from the *start of
the document*, once per AST node — O(length²).

Fixed by precomputing each line's scalar start index alongside the existing offset tables.
Same sizes now measure **8.5ms / 32.5ms / 133ms** — linear, 7.6× faster at 50KB. Parsing
itself accounts for 32ms of that, so the remaining cost is inherent to full-document restyling;
incremental restyling was judged a redesign with worse risk than payoff and was not attempted.
**Guarded:** `testStylingALargeNoteStaysFast` (verified to fail at 1.02s against the old code).

---

---

## Round 2 — an adversarial review of the fixes themselves

The finished diff was reviewed for defects it *introduced*. It found several, including one
critical regression. All are now fixed; the suite is 440 passing.

**R1 (critical, self-inflicted). The 0.4 merge appended a note's own stale text to itself.**
`NoteStore`'s file watcher reports *our own* writes back as `didChange`, and there was no
self-write suppression. Mid-typing, `handleStoreChange` read the note from disk — the version
from the last debounce, not the live buffer — and stored it as an "external" edit, which the
next save then merged in. Any backspace or mid-text edit produced a `--- Conflicted copy`
duplicate of the note's own text from a second earlier. No second app or Mac required.
*Fixed:* the controller records exactly what it last wrote and ignores that echo.
This one is worth noting: the 0.4 fix was correct about the underlying bug and wrong about the
common case, and it took an adversarial pass to catch.

**R2 (high).** A title-only difference bypassed the merge and reverted a rename the user was
still typing, because `needsMerge` weighs only bodies and labels. *Fixed:* a title being
actively edited wins.

**R3 (medium-high).** `closeNote` was the one save path that didn't merge a deferred external
edit, so archiving mid-sync wrote the local buffer over it. *Fixed.*

**R4 (medium).** The debounced work item never cleared itself, so `flushPendingSave` thought a
save was owed for any note ever touched — quitting rewrote every open note, bumping mtimes and
re-uploading them in a synced vault. *Fixed.*

**R5 (medium).** `resolveConflict` wrote even when the merge changed nothing; that write
re-triggers the watcher, so a conflict that wouldn't clear could sustain a 5-second
write→sweep→write cycle, dropping the cache each time. *Fixed:* no-op merges don't write.

**R6 (medium).** The daily-note `fileUnavailable` flag could latch forever, and — the important
part — my original fix largely missed the case it was written for: an evicted iCloud file is
replaced by a hidden `.<name>.icloud` stub, so `fileExists` returns *false* for it. *Fixed:*
the stub is detected, a retry is scheduled, and clearing the pattern resets the flag.

**R7 (low–medium).** A genuinely deleted note re-scanned the whole notes directory on every
keystroke. *Fixed* with a confirmed-deleted set, cleared whenever the tree changes.

**R8 (low).** Tightening the checkbox grammar broke `- [ ]` at end of line (no trailing space),
which editors that strip trailing whitespace produce. *Fixed:* end-of-line is a valid
terminator, and the fourth checkbox regex — in `handleListContinuation`, which I'd missed — now
matches the other three.

Also fixed from that review: the hide-all toast lingering after a new note, dark-mode chrome in
the daily note (same bug as 2.9, different file), hardcoded chords in the quick switcher and
welcome note, over-eager percent-decoding in `Attachments.resolve`, a whitespace-only first body
line being deleted on load, and the legacy daily-state file being deleted even if its
replacement hadn't been written.

**Found incidentally while fixing the above:** `HotkeyAdvice`'s conflict table was keyed `"⌘⇧S"`,
but the shortcut recorder renders chords in canonical macOS order — `"⇧⌘S"`. Every lookup
missed, so the "Also Save As… in many apps" hints never appeared. The existing tests hid it by
only ever feeding hand-written strings; the one test that used the real rendering deliberately
asserted nothing (`_ = ...`). Lookup is now order-insensitive, and that test asserts.

## Notes for the reader

- Three fixes changed behavior that an existing test had pinned. Each was updated deliberately,
  with the reason recorded in the test's doc comment: the unterminated-frontmatter contract
  (2.8) and the removal of the Accessibility-permission tests (3.4).
- The most behavior-visible change is 0.4: an external edit landing while you type now appends
  a `--- Conflicted copy` block instead of one side silently winning.
- The controller layer still has no broad test coverage; the new tests cover the specific
  regressions above, not the layer as a whole.
