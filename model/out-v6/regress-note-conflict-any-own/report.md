# NoteDocument

TLC reached 1,235 states, more than the chart budget of 500, so the chart draws only the bug paths: 3 states and 4 arrows.
The chart has 0 label warnings.

## TypedTextKept breaks
The shortest path has 4 steps:
0. File changed, window not told yet
1. the person types in the note: Typing, save pending
2. the half-second save timer writes the note: File changed, window not told yet
3. the other Mac's deliberate restore arrives as a conflict version: Deliberate restore waiting as a conflict version
4. the conflict sweep merges the conflict version [the window shows it]: File changed, window not told yet

## CloseAlwaysWorks breaks
The shortest path has 4 steps:
0. File changed, window not told yet
1. the person types in the note: Typing, save pending
2. the half-second save timer writes the note: File changed, window not told yet
3. the other Mac's deliberate restore arrives as a conflict version: Deliberate restore waiting as a conflict version
4. the conflict sweep merges the conflict version [the window shows it]: File changed, window not told yet

## Rules that hold
TypeOK, NoSpuriousConflictBlock, NoRepeatedText, OneLifecycleState, PurgeRespectsRetention, WindowMatchesDisk, NoFalseClose, NoUntouchedBlankFile, NoDeadlock

## Label warnings
No label has a warning.

## Arrows
| Label | From | To | TLA+ actions | Steps |
| --- | --- | --- | --- | --- |
| the person types in the note | File changed, window not told yet | Typing, save pending | Type | 1 |
| the half-second save timer writes the note | Typing, save pending | File changed, window not told yet | SaveFires | 1 |
| the other Mac's deliberate restore arrives as a conflict version | File changed, window not told yet | Deliberate restore waiting as a conflict version | ExternalRestoreConflict | 1 |
| the conflict sweep merges the conflict version [the window shows it] | Deliberate restore waiting as a conflict version | File changed, window not told yet | ConflictSweep | 1 |
