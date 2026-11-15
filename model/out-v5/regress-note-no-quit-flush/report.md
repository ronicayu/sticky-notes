# NoteDocument

TLC reached 1,690 states, more than the chart budget of 500, so the chart draws only the bug paths: 6 states and 6 arrows.
The chart has 0 label warnings.

## TypedTextKept breaks
The shortest path has 2 steps:
0. New note, no file yet
1. the person types in the note: New note with text, not written yet
2. the person quits the app: App quit, note on disk

## CloseAlwaysWorks breaks
The shortest path has 5 steps:
0. New note, no file yet
1. the person types in the note: New note with text, not written yet
2. the half-second save timer writes the note: File changed, window not told yet
3. the person types in the note: Typing, save pending
4. the person quits the app: App quit, note on disk
5. the person launches the app: Note open, nothing pending

## Rules that hold
TypeOK, NoSpuriousConflictBlock, NoRepeatedText, OneLifecycleState, PurgeRespectsRetention, WindowMatchesDisk, NoFalseClose, NoUntouchedBlankFile, NoDeadlock

## Label warnings
No label has a warning.

## Arrows
| Label | From | To | TLA+ actions | Steps |
| --- | --- | --- | --- | --- |
| the person types in the note | New note, no file yet | New note with text, not written yet | Type | 1 |
| the person quits the app | New note with text, not written yet | App quit, note on disk | Quit | 1 |
| the half-second save timer writes the note | New note with text, not written yet | File changed, window not told yet | SaveFires | 1 |
| the person types in the note | File changed, window not told yet | Typing, save pending | Type | 1 |
| the person quits the app | Typing, save pending | App quit, note on disk | Quit | 1 |
| the person launches the app | App quit, note on disk | Note open, nothing pending | Relaunch | 1 |
