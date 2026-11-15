# NotePersistence

TLC reached 10,688 states, more than the chart budget of 500, so the chart draws only the bug paths: 3 states and 2 arrows.
The chart has 0 label warnings.

## TypedTextKept breaks
The shortest path has 2 steps:
0. File changed, window not told yet
1. the person types in the note: Typing, save pending
2. the person clicks the note's close button [the note has text]: Note in the archive

## Rules that hold
TypeOK, NoSpuriousConflictBlock, OneLifecycleState, PurgeRespectsRetention, WindowMatchesDisk, NoDeadlock

## Label warnings
No label has a warning.

## Arrows
| Label | From | To | TLA+ actions | Steps |
| --- | --- | --- | --- | --- |
| the person types in the note | File changed, window not told yet | Typing, save pending | Type | 1 |
| the person clicks the note's close button [the note has text] | Typing, save pending | Note in the archive | CloseNote | 1 |
