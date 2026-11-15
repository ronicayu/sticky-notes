# NotePersistence

TLC reached 7,255 states, more than the chart budget of 500, so the chart draws only the bug paths: 6 states and 8 arrows.
The chart has 0 label warnings.

## PurgeRespectsRetention breaks
The shortest path has 4 steps:
0. File changed, window not told yet
1. the calendar moves past the 30-day retention: File changed, window not told yet
2. the person leaves an empty note by closing it or switching away: Note in the Trash
3. the person quits the app: App quit, note on disk
4. the person launches the app: Note file deleted

## TypedTextKept breaks
The shortest path has 6 steps:
0. File changed, window not told yet
1. the person types in the note: Typing, save pending
2. the person clicks the note's close button [the note has text]: Note in the archive
3. the calendar moves past the 30-day retention: Note in the archive
4. the person deletes the note permanently: Note in the Trash
5. the person quits the app: App quit, note on disk
6. the person launches the app: Note file deleted

## Rules that hold
TypeOK, NoSpuriousConflictBlock, OneLifecycleState, WindowMatchesDisk, NoDeadlock

## Label warnings
No label has a warning.

## Arrows
| Label | From | To | TLA+ actions | Steps |
| --- | --- | --- | --- | --- |
| the person types in the note | File changed, window not told yet | Typing, save pending | Type | 1 |
| the calendar moves past the 30-day retention | File changed, window not told yet | File changed, window not told yet | MonthPasses | 1 |
| the person clicks the note's close button [the note has text] | Typing, save pending | Note in the archive | CloseNote | 1 |
| the person leaves an empty note by closing it or switching away | File changed, window not told yet | Note in the Trash | SwitchAway | 1 |
| the calendar moves past the 30-day retention | Note in the archive | Note in the archive | MonthPasses | 1 |
| the person quits the app | Note in the Trash | App quit, note on disk | Quit | 2 |
| the person launches the app | App quit, note on disk | Note file deleted | Relaunch | 2 |
| the person deletes the note permanently | Note in the archive | Note in the Trash | DeleteForever | 1 |
