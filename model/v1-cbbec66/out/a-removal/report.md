# NotePersistence

TLC reached 32,037 states, more than the chart budget of 500, so the chart draws only the bug paths: 2 states and 2 arrows.
The chart has 0 label warnings.

## TypedTextKept breaks
The shortest path has 2 steps:
0. File changed, window not told yet
1. Obsidian or the other Mac edits the file: File changed, window not told yet
2. the other Mac discards the note as empty: Note file deleted

## Rules that hold
TypeOK, NoSpuriousConflictBlock, OneLifecycleState, PurgeRespectsRetention, WindowMatchesDisk, NoDeadlock

## Label warnings
No label has a warning.

## Arrows
| Label | From | To | TLA+ actions | Steps |
| --- | --- | --- | --- | --- |
| Obsidian or the other Mac edits the file | File changed, window not told yet | File changed, window not told yet | ExternalEdit | 1 |
| the other Mac discards the note as empty | File changed, window not told yet | Note file deleted | OtherMacDiscardsEmpty | 1 |
