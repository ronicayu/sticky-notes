# NoteDocument

TLC reached 721 states, more than the chart budget of 500, so the chart draws only the bug paths: 2 states and 1 arrows.
The chart has 0 label warnings.

## TypedTextKept breaks
The shortest path has 1 step:
0. New note with text, not written yet
1. the person quits the app: App quit, note on disk

## Rules that hold
TypeOK, NoSpuriousConflictBlock, NoRepeatedText, OneLifecycleState, PurgeRespectsRetention, WindowMatchesDisk, NoFalseClose, NoUntouchedBlankFile, CloseAlwaysWorks, NoDeadlock

## Label warnings
No label has a warning.

## Arrows
| Label | From | To | TLA+ actions | Steps |
| --- | --- | --- | --- | --- |
| the person quits the app | New note with text, not written yet | App quit, note on disk | Quit | 1 |
