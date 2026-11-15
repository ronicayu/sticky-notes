# NotePersistence

TLC reached 12,932 states, more than the chart budget of 500, so the chart draws only the bug paths: 2 states and 2 arrows.
The chart has 0 label warnings.

## TypedTextKept breaks
The shortest path has 2 steps:
0. File changed, window not told yet
1. Obsidian or the other Mac edits the file: File changed, window not told yet
2. the person clicks the note's close button [the note has text]: Note in the archive

## Rules that hold
TypeOK, NoSpuriousConflictBlock, OneLifecycleState, PurgeRespectsRetention, WindowMatchesDisk, NoDeadlock

## Label warnings
No label has a warning.

## Arrows
| Label | From | To | TLA+ actions | Steps |
| --- | --- | --- | --- | --- |
| Obsidian or the other Mac edits the file | File changed, window not told yet | File changed, window not told yet | ExternalEdit | 1 |
| the person clicks the note's close button [the note has text] | File changed, window not told yet | Note in the archive | CloseNote | 1 |
