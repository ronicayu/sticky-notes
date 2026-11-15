# NotePersistence

TLC reached 11,978 states, more than the chart budget of 500, so the chart draws only the bug paths: 3 states and 4 arrows.
The chart has 0 label warnings.

## TypedTextKept breaks
The shortest path has 4 steps:
0. File changed, window not told yet
1. the person types in the note: Typing, save pending
2. Obsidian or the other Mac edits the file: Typing, save pending
3. the file watcher reports the change [the window holds it back]: Outside edit held back
4. the half-second save timer writes the note: File changed, window not told yet

## Rules that hold
TypeOK, NoSpuriousConflictBlock, OneLifecycleState, PurgeRespectsRetention, WindowMatchesDisk, NoDeadlock

## Label warnings
No label has a warning.

## Arrows
| Label | From | To | TLA+ actions | Steps |
| --- | --- | --- | --- | --- |
| the person types in the note | File changed, window not told yet | Typing, save pending | Type | 1 |
| Obsidian or the other Mac edits the file | Typing, save pending | Typing, save pending | ExternalEdit | 1 |
| the file watcher reports the change [the window holds it back] | Typing, save pending | Outside edit held back | WatcherDelivers | 1 |
| the half-second save timer writes the note | Outside edit held back | File changed, window not told yet | SaveFires | 1 |
