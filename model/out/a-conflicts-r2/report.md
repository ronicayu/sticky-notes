# NotePersistence

TLC reached 9,034 states, more than the chart budget of 500, so the chart draws only the bug paths: 3 states and 2 arrows.
The chart has 0 label warnings.

## TypedTextKept breaks
The shortest path has 2 steps:
0. File changed, window not told yet
1. the other Mac's edit arrives as a conflict version: Other Mac's conflict version waiting
2. the person leaves an empty note by closing it or switching away: Note file deleted

## Rules that hold
TypeOK, NoSpuriousConflictBlock, OneLifecycleState, PurgeRespectsRetention, WindowMatchesDisk, NoDeadlock

## Label warnings
No label has a warning.

## Arrows
| Label | From | To | TLA+ actions | Steps |
| --- | --- | --- | --- | --- |
| the other Mac's edit arrives as a conflict version | File changed, window not told yet | Other Mac's conflict version waiting | ExternalConflict | 1 |
| the person leaves an empty note by closing it or switching away | Other Mac's conflict version waiting | Note file deleted | SwitchAway | 1 |
