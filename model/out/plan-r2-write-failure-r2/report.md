# NotePersistence

TLC reached 4,089 states, more than the chart budget of 500, so the chart draws only the bug paths: 6 states and 5 arrows.
The chart has 0 label warnings.

## TypedTextKept breaks
The shortest path has 2 steps:
0. File changed, window not told yet
1. the person types in the note: Typing, save pending
2. the person clicks the note's close button [the note has text]: Note in the archive

## WindowMatchesDisk breaks
The shortest path has 4 steps:
0. File changed, window not told yet
1. the person types in the note: Typing, save pending
2. the person switches to another window: Save pending, person in another window
3. the file watcher reports the change [the window holds it back]: Outside edit held back
4. the half-second save timer writes the note: Note open, nothing pending

## Rules that hold
TypeOK, NoSpuriousConflictBlock, OneLifecycleState, PurgeRespectsRetention, NoDeadlock

## Label warnings
No label has a warning.

## Arrows
| Label | From | To | TLA+ actions | Steps |
| --- | --- | --- | --- | --- |
| the person types in the note | File changed, window not told yet | Typing, save pending | Type | 1 |
| the person clicks the note's close button [the note has text] | Typing, save pending | Note in the archive | CloseNote | 1 |
| the person switches to another window | Typing, save pending | Save pending, person in another window | SwitchAway | 1 |
| the file watcher reports the change [the window holds it back] | Save pending, person in another window | Outside edit held back | WatcherDelivers | 1 |
| the half-second save timer writes the note | Outside edit held back | Note open, nothing pending | SaveFires | 1 |
