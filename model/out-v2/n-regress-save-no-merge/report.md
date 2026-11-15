# NoteDocument

TLC reached 1,223 states, more than the chart budget of 500, so the chart draws only the bug paths: 4 states and 6 arrows.
The chart has 0 label warnings.

## TypedTextKept breaks
The shortest path has 6 steps:
0. New note, no file yet
1. the person types in the note: New note, no file yet
2. the half-second save timer writes the note: File changed, window not told yet
3. the person types in the note: Typing, save pending
4. Obsidian or the other Mac appends a line to the file: Typing, save pending
5. the file watcher reports the change to the window [the window holds it back]: Outside edit held back
6. the half-second save timer writes the note: File changed, window not told yet

## CloseAlwaysWorks breaks
The shortest path has 6 steps:
0. New note, no file yet
1. the person types in the note: New note, no file yet
2. the half-second save timer writes the note: File changed, window not told yet
3. the person types in the note: Typing, save pending
4. Obsidian or the other Mac appends a line to the file: Typing, save pending
5. the file watcher reports the change to the window [the window holds it back]: Outside edit held back
6. the half-second save timer writes the note: File changed, window not told yet

## Rules that hold
TypeOK, NoSpuriousConflictBlock, NoRepeatedText, OneLifecycleState, PurgeRespectsRetention, WindowMatchesDisk, NoFalseClose, NoUntouchedBlankFile, NoDeadlock

## Label warnings
No label has a warning.

## Arrows
| Label | From | To | TLA+ actions | Steps |
| --- | --- | --- | --- | --- |
| the person types in the note | New note, no file yet | New note, no file yet | Type | 1 |
| the half-second save timer writes the note | New note, no file yet | File changed, window not told yet | SaveFires | 1 |
| the person types in the note | File changed, window not told yet | Typing, save pending | Type | 1 |
| Obsidian or the other Mac appends a line to the file | Typing, save pending | Typing, save pending | ExternalEdit | 1 |
| the file watcher reports the change to the window [the window holds it back] | Typing, save pending | Outside edit held back | WindowHears | 1 |
| the half-second save timer writes the note | Outside edit held back | File changed, window not told yet | SaveFires | 1 |
