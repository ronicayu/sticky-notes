# NoteDocument

TLC reached 8,227 states, more than the chart budget of 500, so the chart draws only the bug paths: 2 states and 3 arrows.
The chart has 1 label warning.

## CloseAlwaysWorks breaks
The shortest path has 4 steps:
0. File changed, window not told yet
1. the person types in the note: Typing, save pending
2. the half-second save timer writes the note: File changed, window not told yet
3. the person types in the note: Typing, save pending
4. ExternalRestore: Typing, save pending

## TypedTextKept breaks
The shortest path has 5 steps:
0. File changed, window not told yet
1. the person types in the note: Typing, save pending
2. the half-second save timer writes the note: File changed, window not told yet
3. the person types in the note: Typing, save pending
4. ExternalRestore: Typing, save pending
5. the half-second save timer writes the note: File changed, window not told yet

## Rules that hold
TypeOK, NoSpuriousConflictBlock, NoRepeatedText, OneLifecycleState, PurgeRespectsRetention, WindowMatchesDisk, NoFalseClose, NoUntouchedBlankFile, NoDeadlock

## Label warnings
- The arrow label "ExternalRestore" from "Typing, save pending" to "Typing, save pending" is too short to name its actor.

## Arrows
| Label | From | To | TLA+ actions | Steps |
| --- | --- | --- | --- | --- |
| the person types in the note | File changed, window not told yet | Typing, save pending | Type | 2 |
| the half-second save timer writes the note | Typing, save pending | File changed, window not told yet | SaveFires | 2 |
| ExternalRestore | Typing, save pending | Typing, save pending | ExternalRestore | 1 |
