# NotePersistence

TLC reached 546 states, more than the chart budget of 500, so the chart draws only the bug paths: 4 states and 4 arrows.
The chart has 0 label warnings.

## TypedTextKept breaks
The shortest path has 4 steps:
0. File changed, window not told yet
1. the person types in the note: Typing, save pending
2. the person switches to another window: Save pending, person in another window
3. the person archives the note from the notes panel: Note in the archive
4. the person clicks the note's close button [the note has text]: Note in the archive

## Rules that hold
TypeOK, NoSpuriousConflictBlock, OneLifecycleState, PurgeRespectsRetention, WindowMatchesDisk, NoDeadlock

## Label warnings
No label has a warning.

## Arrows
| Label | From | To | TLA+ actions | Steps |
| --- | --- | --- | --- | --- |
| the person types in the note | File changed, window not told yet | Typing, save pending | Type | 1 |
| the person switches to another window | Typing, save pending | Save pending, person in another window | SwitchAway | 1 |
| the person archives the note from the notes panel | Save pending, person in another window | Note in the archive | PanelArchive | 1 |
| the person clicks the note's close button [the note has text] | Note in the archive | Note in the archive | CloseNote | 1 |
