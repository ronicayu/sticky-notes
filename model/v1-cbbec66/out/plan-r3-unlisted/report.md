# NotePersistence

TLC reached 1,607 states, more than the chart budget of 500, so the chart draws only the bug paths: 4 states and 3 arrows.
The chart has 0 label warnings.

## TypedTextKept breaks
The shortest path has 3 steps:
0. File changed, window not told yet
1. the person types in the note: Typing, save pending
2. iCloud hides the file for a moment: Note file briefly missing
3. the file watcher reports the note gone: Note on disk, window closed

## Rules that hold
TypeOK, NoSpuriousConflictBlock, OneLifecycleState, PurgeRespectsRetention, WindowMatchesDisk, NoDeadlock

## Label warnings
No label has a warning.

## Arrows
| Label | From | To | TLA+ actions | Steps |
| --- | --- | --- | --- | --- |
| the person types in the note | File changed, window not told yet | Typing, save pending | Type | 1 |
| iCloud hides the file for a moment | Typing, save pending | Note file briefly missing | FileVanishes | 1 |
| the file watcher reports the note gone | Note file briefly missing | Note on disk, window closed | WatcherDelivers | 1 |
