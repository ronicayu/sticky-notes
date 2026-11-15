# NoteDocument

TLC reached 9,556 states, more than the chart budget of 500, so the chart draws only the bug paths: 7 states and 7 arrows.
The chart has 0 label warnings.

## TypedTextKept breaks
The shortest path has 7 steps:
0. New note, no file yet
1. the person types in the note: New note with text, not written yet
2. the half-second save timer writes the note: File changed, window not told yet
3. the person types in the note: Typing, save pending
4. the other Mac archives, trashes or deletes the file: Window open, note moved to the Trash
5. the calendar moves past the 30-day retention: Window open, note moved to the Trash
6. the person quits the app: App quit, note on disk
7. the person launches the app: No note file, window closed

## PurgeRespectsRetention breaks
The shortest path has 7 steps:
0. New note, no file yet
1. the person types in the note: New note with text, not written yet
2. the half-second save timer writes the note: File changed, window not told yet
3. the person types in the note: Typing, save pending
4. the other Mac archives, trashes or deletes the file: Window open, note moved to the Trash
5. the calendar moves past the 30-day retention: Window open, note moved to the Trash
6. the person quits the app: App quit, note on disk
7. the person launches the app: No note file, window closed

## Rules that hold
TypeOK, NoSpuriousConflictBlock, NoRepeatedText, OneLifecycleState, WindowMatchesDisk, NoFalseClose, NoUntouchedBlankFile, CloseAlwaysWorks, NoDeadlock

## Label warnings
No label has a warning.

## Arrows
| Label | From | To | TLA+ actions | Steps |
| --- | --- | --- | --- | --- |
| the person types in the note | New note, no file yet | New note with text, not written yet | Type | 1 |
| the half-second save timer writes the note | New note with text, not written yet | File changed, window not told yet | SaveFires | 1 |
| the person types in the note | File changed, window not told yet | Typing, save pending | Type | 1 |
| the other Mac archives, trashes or deletes the file | Typing, save pending | Window open, note moved to the Trash | ExternalMove | 1 |
| the calendar moves past the 30-day retention | Window open, note moved to the Trash | Window open, note moved to the Trash | MonthPasses | 1 |
| the person quits the app | Window open, note moved to the Trash | App quit, note on disk | Quit | 1 |
| the person launches the app | App quit, note on disk | No note file, window closed | Relaunch | 1 |
