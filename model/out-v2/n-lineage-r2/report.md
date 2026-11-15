# NoteDocument

TLC reached 42,055 states, more than the chart budget of 500, so the chart draws only the bug paths: 5 states and 7 arrows.
The chart has 1 label warning.

## NoSpuriousConflictBlock breaks
The shortest path has 9 steps:
0. New note, no file yet
1. the person types in the note: New note, no file yet
2. the half-second save timer writes the note: File changed, window not told yet
3. the person types in the note: Typing, save pending
4. the half-second save timer writes the note: File changed, window not told yet
5. the person types in the note: Typing, save pending
6. iCloud keeps an older save as a conflict version: Older own save kept as a conflict version
7. the half-second save timer writes the note: Older own save kept as a conflict version
8. Obsidian rewrites the file from an older copy: Older own save kept as a conflict version
9. the conflict sweep merges the conflict version [the window holds it back]: Outside edit held back

## Rules that hold
TypeOK, TypedTextKept, NoRepeatedText, OneLifecycleState, PurgeRespectsRetention, WindowMatchesDisk, NoFalseClose, NoUntouchedBlankFile, CloseAlwaysWorks, NoDeadlock

## Label warnings
- The tool joined 2 labels into "the half-second save timer writes the note or Obsidian rewrites the file from an older copy" from "Older own save kept as a conflict version" to "Older own save kept as a conflict version". Give each arrow its own destination or its own label.

## Arrows
| Label | From | To | TLA+ actions | Steps |
| --- | --- | --- | --- | --- |
| the person types in the note | New note, no file yet | New note, no file yet | Type | 1 |
| the half-second save timer writes the note | New note, no file yet | File changed, window not told yet | SaveFires | 1 |
| the person types in the note | File changed, window not told yet | Typing, save pending | Type | 2 |
| the half-second save timer writes the note | Typing, save pending | File changed, window not told yet | SaveFires | 1 |
| iCloud keeps an older save as a conflict version | Typing, save pending | Older own save kept as a conflict version | ICloudSelfConflict | 1 |
| the half-second save timer writes the note or Obsidian rewrites the file from an older copy | Older own save kept as a conflict version | Older own save kept as a conflict version | ObsidianStaleRewrite, SaveFires | 2 |
| the conflict sweep merges the conflict version [the window holds it back] | Older own save kept as a conflict version | Outside edit held back | ConflictSweep | 1 |
