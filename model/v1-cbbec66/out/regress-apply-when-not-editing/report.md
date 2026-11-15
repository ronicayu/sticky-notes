# NotePersistence

TLC reached 16,296 states, more than the chart budget of 500, so the chart draws only the bug paths: 3 states and 3 arrows.
The chart has 0 label warnings.

## TypedTextKept breaks
The shortest path has 3 steps:
0. File changed, window not told yet
1. the person types in the note: Typing, save pending
2. the person grabs the note's title bar: Typing, save pending, caret out of the text
3. the file watcher reports the change [the window shows it]: Typing, save pending, caret out of the text

## Rules that hold
TypeOK, NoSpuriousConflictBlock, OneLifecycleState, PurgeRespectsRetention, WindowMatchesDisk, NoDeadlock

## Label warnings
No label has a warning.

## Arrows
| Label | From | To | TLA+ actions | Steps |
| --- | --- | --- | --- | --- |
| the person types in the note | File changed, window not told yet | Typing, save pending | Type | 1 |
| the person grabs the note's title bar | Typing, save pending | Typing, save pending, caret out of the text | GrabTitleBar | 1 |
| the file watcher reports the change [the window shows it] | Typing, save pending, caret out of the text | Typing, save pending, caret out of the text | WatcherDelivers | 1 |
