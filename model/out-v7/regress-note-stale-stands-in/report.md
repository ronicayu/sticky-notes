# NoteDocument

TLC reached more states than the chart budget of 500, so the chart draws only the bug paths: 5 states and 7 arrows.
The chart has 0 label warnings.

## TypedTextKept breaks
The shortest path has 7 steps:
0. New note, no file yet
1. the person types in the note: New note with text, not written yet
2. the half-second save timer writes the note: File changed, window not told yet
3. the person types in the note: Typing, save pending
4. the half-second save timer writes the note: File changed, window not told yet
5. iCloud keeps an older save as a conflict version: Older own save kept as a conflict version
6. the other Mac puts an earlier version of the text back on purpose: Older own save kept as a conflict version
7. the conflict sweep merges the conflict version [the window shows it]: File changed, window not told yet

## CloseAlwaysWorks breaks
The shortest path has 7 steps:
0. New note, no file yet
1. the person types in the note: New note with text, not written yet
2. the half-second save timer writes the note: File changed, window not told yet
3. the person types in the note: Typing, save pending
4. the half-second save timer writes the note: File changed, window not told yet
5. iCloud keeps an older save as a conflict version: Older own save kept as a conflict version
6. the other Mac puts an earlier version of the text back on purpose: Older own save kept as a conflict version
7. the conflict sweep merges the conflict version [the window shows it]: File changed, window not told yet

## Rules not checked
TypeOK, NoSpuriousConflictBlock, NoRepeatedText, OneLifecycleState, PurgeRespectsRetention, WindowMatchesDisk, NoFalseClose, NoUntouchedBlankFile, NoDeadlock
After the first break, each TLC run stops at 100,000 distinct states. A run reached that bound before it checked these rules in every state.

## Label warnings
No label has a warning.

## Arrows
| Label | From | To | TLA+ actions | Steps |
| --- | --- | --- | --- | --- |
| the person types in the note | New note, no file yet | New note with text, not written yet | Type | 1 |
| the half-second save timer writes the note | New note with text, not written yet | File changed, window not told yet | SaveFires | 1 |
| the person types in the note | File changed, window not told yet | Typing, save pending | Type | 1 |
| the half-second save timer writes the note | Typing, save pending | File changed, window not told yet | SaveFires | 1 |
| iCloud keeps an older save as a conflict version | File changed, window not told yet | Older own save kept as a conflict version | ICloudSelfConflict | 1 |
| the other Mac puts an earlier version of the text back on purpose | Older own save kept as a conflict version | Older own save kept as a conflict version | ExternalRestore | 1 |
| the conflict sweep merges the conflict version [the window shows it] | Older own save kept as a conflict version | File changed, window not told yet | ConflictSweep | 1 |
