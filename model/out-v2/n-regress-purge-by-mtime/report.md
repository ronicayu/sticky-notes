# NoteDocument

TLC reached 8,656 states, more than the chart budget of 500, so the chart draws only the bug paths: 5 states and 6 arrows.
The chart has 0 label warnings.

## TypedTextKept breaks
The shortest path has 6 steps:
0. New note, no file yet
1. the person types in the note: New note, no file yet
2. the person clicks the note's close button: Note in the archive, window closed
3. the calendar moves past the 30-day retention: Note in the archive, window closed
4. the person deletes the note permanently: Note in the Trash, window closed
5. the person quits the app: App quit, note on disk
6. the person launches the app: No note file, window closed

## PurgeRespectsRetention breaks
The shortest path has 6 steps:
0. New note, no file yet
1. the person types in the note: New note, no file yet
2. the person clicks the note's close button: Note in the archive, window closed
3. the calendar moves past the 30-day retention: Note in the archive, window closed
4. the person deletes the note permanently: Note in the Trash, window closed
5. the person quits the app: App quit, note on disk
6. the person launches the app: No note file, window closed

## Rules that hold
TypeOK, NoSpuriousConflictBlock, NoRepeatedText, OneLifecycleState, WindowMatchesDisk, NoFalseClose, NoUntouchedBlankFile, CloseAlwaysWorks, NoDeadlock

## Label warnings
No label has a warning.

## Arrows
| Label | From | To | TLA+ actions | Steps |
| --- | --- | --- | --- | --- |
| the person types in the note | New note, no file yet | New note, no file yet | Type | 1 |
| the person clicks the note's close button | New note, no file yet | Note in the archive, window closed | CloseNote | 1 |
| the calendar moves past the 30-day retention | Note in the archive, window closed | Note in the archive, window closed | MonthPasses | 1 |
| the person deletes the note permanently | Note in the archive, window closed | Note in the Trash, window closed | DeleteForever | 1 |
| the person quits the app | Note in the Trash, window closed | App quit, note on disk | Quit | 1 |
| the person launches the app | App quit, note on disk | No note file, window closed | Relaunch | 1 |
