# NoteDocument

TLC reached 6,486 states, more than the chart budget of 500, so the chart draws only the bug paths: 2 states and 3 arrows.
The chart has 0 label warnings.

## CloseAlwaysWorks breaks
The shortest path has 4 steps:
0. File changed, window not told yet
1. the person types in the note: Typing, save pending
2. the half-second save timer writes the note: File changed, window not told yet
3. the person types in the note: Typing, save pending
4. the other Mac puts an earlier version of the text back on purpose: Typing, save pending

## TypedTextKept breaks
The shortest path has 5 steps:
0. File changed, window not told yet
1. the person types in the note: Typing, save pending
2. the half-second save timer writes the note: File changed, window not told yet
3. the person types in the note: Typing, save pending
4. the other Mac puts an earlier version of the text back on purpose: Typing, save pending
5. the half-second save timer writes the note: File changed, window not told yet

## Rules that hold
TypeOK, NoSpuriousConflictBlock, NoRepeatedText, OneLifecycleState, PurgeRespectsRetention, WindowMatchesDisk, NoFalseClose, NoUntouchedBlankFile, NoDeadlock

## Label warnings
No label has a warning.

## Arrows
| Label | From | To | TLA+ actions | Steps |
| --- | --- | --- | --- | --- |
| the person types in the note | File changed, window not told yet | Typing, save pending | Type | 2 |
| the half-second save timer writes the note | Typing, save pending | File changed, window not told yet | SaveFires | 2 |
| the other Mac puts an earlier version of the text back on purpose | Typing, save pending | Typing, save pending | ExternalRestore | 1 |
