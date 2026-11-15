# NoteDocument

TLC reached 41,371 states, more than the chart budget of 500, so the chart draws only the bug paths: 5 states and 5 arrows.
The chart has 0 label warnings.

## NoSpuriousConflictBlock breaks
The shortest path has 5 steps:
0. New note, no file yet
1. the person types in the note: New note, no file yet
2. the half-second save timer writes the note: File changed, window not told yet
3. the person types in the note: Typing, save pending
4. the file watcher reports the change to the window [the window holds it back]: Outside edit held back
5. the person switches to another window: Save pending, person in another window

## Rules that hold
TypeOK, TypedTextKept, NoRepeatedText, OneLifecycleState, PurgeRespectsRetention, WindowMatchesDisk, NoFalseClose, NoUntouchedBlankFile, CloseAlwaysWorks, NoDeadlock

## Label warnings
No label has a warning.

## Arrows
| Label | From | To | TLA+ actions | Steps |
| --- | --- | --- | --- | --- |
| the person types in the note | New note, no file yet | New note, no file yet | Type | 1 |
| the half-second save timer writes the note | New note, no file yet | File changed, window not told yet | SaveFires | 1 |
| the person types in the note | File changed, window not told yet | Typing, save pending | Type | 1 |
| the file watcher reports the change to the window [the window holds it back] | Typing, save pending | Outside edit held back | WindowHears | 1 |
| the person switches to another window | Outside edit held back | Save pending, person in another window | SwitchAway | 1 |
