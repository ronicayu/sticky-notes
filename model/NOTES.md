# Model notes (v3)

Code modelled: commit `c16cef1` (branch `masterpiece`, Phase 0 and 1 complete) with the fixes of N1-N6 (`414f4d9`,
`5d21840`) and of the two reviews (`12cd68b`, `98c055b`). Every file:line below is `git show c16cef1:<path>`; the fixes moved the lines of `ConflictResolver`,
`NoteStore`, `NoteDocument`, `DailyDocument`, `DeskController` and `WriteLineage` (now in `NoteStore.swift`). HEAD was `6838780` when the work began; later commits (to `83e94dc`) change
geometry and comments in `NoteDocument.swift` and `DailyDocument.swift` and add layout pruning to
`DeskController.reconcileOpenWindows`, which do not change a modelled transition. Re-checked at `9f58340`:
`ConflictResolver.swift` unchanged; the changes to `NoteStore` (layout, storage switch, legacy placement),
`NoteWindowController` and the new Note menu (⌘W calls `closeNote`) touch no modelled transition; the anchors of
N1-N6 are all still there.

The cbbec66 models, configs and outputs stay in `v1-cbbec66/` as the record of the first run, the `c16cef1` run
in `out-v3/`.

## Files

| File | What |
| --- | --- |
| `LineMerge.tla` | Text operators shared by both models: `Covered`, `Superset`, `MergeVersions`, `MergeBodies`, `ThreeWay`, `NoRepeat` |
| `NoteDocument.tla` | Model (a): one note in Obsidian vault mode, vault in iCloud Drive |
| `DailyDocument.tla` | Model (b): today's daily note across midnight, this Mac plus the other Mac through iCloud |
| `n-*.cfg`, `d-*.cfg`, `regress-*.cfg` | Configs; `regress-note-*` and `regress-daily-*` are the faithfulness configs (one per fixed bug, N1-N6 included) |
| `note-doc-view.mjs`, `daily-doc-view.mjs` | Chart views |
| `out-v6/<config>/` | `report.md`, `chart.mmd`, `tlc.out` of every config on the fixed code (`out-v3/` is the run of `c16cef1`) |
| `run-all.sh` | Reruns every config and the base check |

## Switch convention

- `ALLOW_OLD_*` = FALSE is the code as it is. TRUE brings back one behaviour that a commit since the first
  run fixed. (In v1 the sign was the other way round.)
- `ALLOW_OLD_OWN_COPY_BLOCK`, `ALLOW_OLD_BLANK_WINNER_BLOCK`, `ALLOW_OLD_LINEAGE_RESET`, `ALLOW_OLD_LINEAGE_NEEDS_NEWEST`,
  `ALLOW_OLD_CLOSE_REFUSED_UNREADABLE`, `ALLOW_OLD_NO_MERGE_RETRY` are the findings N1-N6 of the `c16cef1` run. They
  were `ALLOW_*` = TRUE for the code as it was; after the fixes they follow the same convention as the older
  switches: FALSE is the fixed code, TRUE brings the `c16cef1` behaviour back. The configs that showed each finding
  are now `regress-*` configs with the switch TRUE, and the plain config of the same chain has it FALSE.
- `ALLOW_OLD_RESTORE_KEEPS_BUFFER` (F1, `414f4d9`) and `ALLOW_OLD_STALE_STANDS_IN` (F2, `5d21840`) are the two regressions the review found.
- `ALLOW_OLD_CONFLICT_ANY_OWN` (`414f4d9`, F3): a conflict version equal to an earlier own write was dropped whoever saved it and whenever. Fixed: the model labels a deliberate restore that arrives as a conflict version `restore` and never drops it; in the code that is the version's date and saving computer.
- `EXCUSE_STALE_BLOCK` is not an old behaviour but a design choice, TRUE everywhere except `n-probe-stale-block`: a block of two own texts after an earlier own file was kept next to our newest text is not counted as spurious.
- Environment constants (`ALLOW_EXTERNAL_EDIT`, ...) only switch an actor on; `ALLOW_RESTORE_AS_CONFLICT` and `ALLOW_ICLOUD_OLDER_WINS` switch on `ExternalRestoreConflict` and `ICloudSelfConflictOlderWins` (iCloud keeps the older own save as the file and the newest as the conflict version); `ALLOW_EXTERNAL_RESTORE` switches on `ExternalRestore`: an earlier own write is put back on purpose, and the tokens it re-adds count as typed by the person (a stale rewrite adds the tokens it removes to `extRemoved` instead).

## Abstractions

- A body is a sequence of line tokens. `c` captured text, `a` `b` typed lines, `r` the first line after a
  backspace or mid-line edit (replaces it), `x` `y` lines another writer appended, `D` a divider. Sequences,
  not sets, so that a merge that repeats a line is visible (`NoRepeatedText`) and so that `isCovered`
  (multiset of lines) and `isSuperset` (subsequence) are the real tests. A cut-off last line (the prefix rule
  in `isCovered`) is not modelled: every line is whole.
- The fingerprint is a relation: `fp` = "ok" (the document's fingerprint matches the file now), "stale",
  or "none" (the document expects no file). Own writes and adopting a read make it "ok"; any outside write,
  a frontmatter-only rewrite or an iCloud download makes it "stale". A save with "ok" writes, with "stale" or
  "none" finds a conflict, merges and writes.
- `linM` holds the bodies that only the store wrote as a conflict merge, heal or copy (`Entry.merged`): they are in `lin` (the file holds them) but `Own(t) = lin \ linM` is what vouches for an earlier version, a put-back body or a stale file. `ExternalRestore` re-adds tokens that count as typed and are taken out of `extRemoved`.
- `base` is `persistedContent`. `lin`/`linNew` are `WriteLineage` (set of own written bodies, newest); the lineage
  is saved in a file and survives a relaunch. It ends only in `Adopted`: a document took over text (`apply`,
  `MergeIn`, `Opened`, daily `Adopt`) that lacks lines of what it showed (or of the newest write when it started
  from the file), and `brk` remembers that. Reads change nothing. `DropsOwn`: an own conflict version that is not
  the newest write is dropped while the file covers the newest write's text (`Covered`) or is an earlier write of
  ours (`StaleFile`: if the newest text covers the file it stands in and is written back, `stands`; if not, the file may be a restore on purpose and the newest text is merged as one more version, `added`). `MergeIn` keeps the
  buffer, with no block, for a held-back outside body that is an earlier own write other than the newest and that
  the base covers (`ALLOW_OLD_RESTORE_KEEPS_BUFFER` drops the last condition), when the buffer has unsaved edits.
  `ALLOW_OLD_STALE_STANDS_IN` makes the newest text stand in whether or not it covers the file. `ALLOW_OLD_LINEAGE_RESET` brings back the c16cef1 rules: a read ends the lineage unless
  the file holds the newest write, a quit ends it, nothing else does.
- Provenance for `NoSpuriousConflictBlock`: a block under a divider is warranted when each side holds text the
  other lacks and one side's extra text is outside-authored (`Outside` = `x`, `y` / `b2`). Two versions of this
  person's own text are not a conflict, except after `brk`: when the lineage ended because outside text took lines
  out, an earlier own save may hold the only copy of them, and the block is the safe outcome.
- `persist()`'s three attempts and `resolveConflict` are one atomic step: they run on the main thread. The
  check-then-write gap in `NoteStore.save` (comment at NoteStore.swift:260) is left out.
- One conflict version at a time. Title, labels, colour, geometry and `preserved` are not modelled; the body
  decides everything in the properties above.
- Time: debounces, retry back-off and the 5 s sweep limit are interleavings, not clocks. "30 days pass" is one
  step. Failures are finite: `flaky` (2) bounds how often the disk, the listing or iCloud misbehave, so the
  no-stuck rules can be checked.
- Use case (MASTERPIECE-PLAN Conclusion): the second Mac has no window. It writes after a sync
  (`ExternalEdit`, `BEditsOnline`), edits an older copy offline (`ExternalConflict`, `BEditsOffline`: a
  conflict version), or creates the day's file offline (`BCreatesOffline`: a numbered duplicate). Two people
  editing at once, R8 and the two-Mac form of R10 are dropped.
- Kept from before: sync delay (`unseen`), iCloud self-conflicts, Obsidian on the same Mac, eviction to a
  placeholder, duplicate healing, Quit and Relaunch, Trash retention.

## Model (a) actions -> code (c16cef1)

| Action | Code |
| --- | --- |
| `Init` | `DeskController.makeNote` 189-235 (a blank note has no file; a captured one is written at once, 217-220); `NoteDocument.init` 141-154 |
| `Type` | `NoteDocument.edit` 194-199 -> `scheduleSave` 445-463 (`createsFileOnFirstEdit` guard 447) |
| `SaveFires` | `scheduleSave` work item 451-462 -> `mergePendingExternal` 329-375 (N1: `isEarlierOwnBody`) -> `persist` 486-525 |
| `SwitchAway` | `NoteWindowController.windowDidResignKey` 704-718; abandoned capture -> `close(.discard)` NoteDocument.swift 606-644; else `blur` 306-310 |
| `CloseNote`, `PanelArchive` | `NoteWindowController.closeNote` 503-513 -> `closeThroughDocument` 515-528 -> `NoteDocument.close(.archive)` 624-643; `DeskController.archiveNote` 154-161; `onCloseRefused` (stranded or `fileCannotBeRead` -> recovery, N3) |
| `Quit` | `AppDelegate.applicationShouldTerminate` 76-83 -> `DeskController.flushForQuit` 612-617 -> `NoteDocument.flush` 596-602, `RecoveryFiles.write` |
| `Relaunch` | `NoteStore.init` -> `purgeExpiredTrash` 612-633, `restoreActiveNotes`; `AppDelegate.init` loads the lineage file (`WriteLineage.useFile`), `applicationWillTerminate` saves it; the restored window calls `WriteLineage.adopted` (`Opened`) |
| `Restore`, `DeleteForever`, `RestoreFromTrash`, `MonthPasses` | NoteStore.swift 518-530, 545-574, 580-590 |
| `WindowHears` | `NoteStore.handleFileSystemEvent` 979-983 -> `NoteDocument.storeDidChange` 245-253 -> `externalChange` 257-297 -> `apply` (`WriteLineage.adopted`, the `Apply` of the model) |
| `Reconcile` | `DeskController.reconcileOpenWindows` 379-403, `isGone` 409-415, `closeKeepingText` 420-425 -> `NoteDocument.close(.externalDeletion)` 614-623 |
| `ConflictSweep` | `NoteStore.resolveConflict` with `beforeResolvingConflicts` (DeskController 39-41 -> `flushPendingSave`), `ConflictResolver.handlingStaleFile` (`StaleFile`, `stands`, `added`), `versionsToMerge` (`DropsOwn`) and `merge` (blank winner, N2); a failed write or flush arms `settleConflictRetry` (N6) |
| persist cases | `save` 272-326 (`.gone` 305, `.failed(locationUnknown)` 295), `writeIfUnchanged` 330-349; `NoteDocument.persist` 486-525; `keepTextElsewhere` 544-564 via `whereIs` 372-394, `save(in:)` 414-425, `saveRecoveredCopy` 430-448 |
| `ExternalEdit`, `ExternalMetaWrite`, `ObsidianStaleRewrite` | Obsidian or the other Mac writes the file |
| `ExternalConflict`, `ICloudSelfConflict` | iCloud keeps a conflict version (`NSFileVersion`); self-conflict is hypothesis H1 of the first report |
| `ExternalMove` | the other Mac runs `archive` 491-497, `discardActive` 502-516, or deletes the file |
| `FileVanishes`, `PlaceholderAppears` | `listActive` nil / `.failed(unreadableOnDisk)` 336 / `whereIs` unknown 393 |
| `DiskFills` | any write fails (`.failed`) |

## Model (b) actions -> code (c16cef1)

| Action | Code |
| --- | --- |
| `Midnight` | wall clock |
| `Rollover`, `UnavailableRetry` | `DailyDocument.rolloverIfNeeded` 466-477 (flush first, `.blocked` if it fails, `armRolloverRetry` 479-486), `load` 306-345 (heal 314, resolve conflicts 317, read 323, placeholder 331-341, seed 344), unavailable retry 336-340 |
| `Type`, `RewriteTypo`, `SaveFires` | `setBody` 361-364 (refused while unavailable), `NoteDocument.edit` / `persist` through `DailyFile.save` 62-87 |
| `PersonOpensToday` | `createTodaysFileIfMissing` 536-544 |
| `SwitchAway` | `blur` 367-369 |
| `WatcherDelivers` | `storeDidChange` 381-401: flush + heal when due (387-388), `resolveConflictVersions` (flush must succeed, else or on a failed merge write `armConflictRetry`, N6), read, adopt or `externalChange` |
| heal | `DailyNote.healDuplicates` (DailyDocument.swift 415-428) |
| conflict merge | `DailyFile.resolveConflictsReporting` with `WriteLineage` (write recorded in `writeRecording`; `handlingStaleFile`, `versionsToMerge`) |
| `Upload`, `Download`, `Evict`, `SelfConflict`, `BEditsOnline`, `BEditsOffline`, `BCreatesOffline`, `BUploads` | iCloud Drive and the other Mac |

## Predictions and outcome

Written from reading the code before the first run, compared after.

| Prediction | Outcome |
| --- | --- |
| All rules hold on the current code, except the lineage trade-off that the code comment names (N4, N5) and a blank winner in `ConflictResolver.merge` (N2: `isSuperset` returns false for a blank base) | N2, N4, N5 confirmed; **three surprises**: N1 (outside rewrite back to an older own copy), N3 (close refused while the file cannot be read), N6 (a merge that cannot be written has no retry) |
| Every regress config breaks | 36 of 44 break. **Surprise:** 8 single-switch configs held because a newer fix hides the old bug (`stale-fp-echo`, `no-echo-filter`, `sweep-no-flush` in both models, `heal-no-flush`, `panel-no-flush`, and each half of F3). Each has a pair config that breaks (with `UNBASED_MERGE`, with `RECONCILE_DROPS`, or both F3 halves) |
| `CloseAlwaysWorks` holds | held on every config once N3 was fixed; broke on `ALLOW_OLD_STRANDED_CLOSE_REFUSED` |
| Daily `NoSpuriousConflictBlock` cannot break (daily edits only append) | broke once `RewriteTypo` was added: the daily lineage is what stops it |

## Model artefacts found and fixed during the work

1. `ExternalEdit` reused a token after `EraseAll` cleared `typed`, so the same line was appended twice. Fixed: a
   separate `used` set.
2. `Genuine` asked for outside text on the loser side only, so "this Mac's text against the other Mac's text"
   with the other Mac winning looked spurious. Fixed: symmetric, outside text on either side.
3. `ALLOW_OLD_BLANK_WINNER_BLOCK` was passed to `MergeVersions` with the wrong sign. Fixed.
4. `Download`/`Upload` did not mark the stored fingerprint stale or the file as foreign, so a daily save
   after a download overwrote it and `prev` held the other Mac's text. Fixed (`StaleFp`, `diskOwn`).
5. `Quit` cleared the lineage from the pre-flush state. Fixed.
6. Recovery files replaced each other in the model; the code writes a new file each time. Fixed: `recDir` is a
   set.
7. `NoRepeatedText` broke on an outside writer saving the same text the window shows (`ExternalCopy`). That
   action is a duplicate-typing artefact in a token model and was removed, together with the
   `NO_BASE_ON_EQUAL` switch it served (`testAFileThatMatchesTheBufferBecomesTheBaseForLaterMerges` is
   not checkable here).
8. The liveness check as `ENABLED` of a close step made TLC 100 times slower; it is now a state predicate
   (`CloseAlwaysWorks`). A temporal property over the daily conflict versions did not finish; it is now the
   invariant `ConflictVersionsMerged`.

9. (v3) The first model of the N4/N5 fix let a held-back outside body that equalled the newest write be taken for
   "an older copy of our own text": the newest write can be a merge that holds the other Mac's text, and the model found
   `TypedTextKept` broken. Fixed in the model and in the code (`5d21840`): only writes other than the newest count.
10. (v3) `NoSpuriousConflictBlock` counts a block of two own versions after the lineage ended (`brk`) as warranted; the
   token model cannot tell "own text" from "own text that an outside writer removed".

## Left out

Labels, title, colour, geometry, frontmatter beyond the fingerprint bit (1.8), the storage switch (1.5, R12),
the sweep moved off the launch path (1.6, same ordering as before), retry back-off timing, the check-then-write
gap in `NoteStore.save`, an unreadable file with a different name being judged missing, R8 and the two-Mac form
of R10 (dropped by the use case), several conflict versions at once, nested divider counts (one `D` token).

## How to rerun

```sh
cd /Users/ronica/projects/sticky-notes/.claude/worktrees/masterpiece/model
R=/Users/ronica/.claude/plugins/cache/ronica-skills/statechart/0.3.0/skills/statechart/scripts/statechart
export TLA2TOOLS=$HOME/.cache/statechart/tla2tools.jar JAVA=/opt/homebrew/opt/openjdk/bin/java
$R NoteDocument.tla --config n-edits.cfg --view note-doc-view.mjs --out out-new/n-edits
$R DailyDocument.tla --config d-create.cfg --view daily-doc-view.mjs --out out-new/d-create
./run-all.sh out-new      # every config, then the base check of every regress config
```

Use a new `--out` folder each run.
