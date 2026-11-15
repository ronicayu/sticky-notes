# NoteDocument

TLC reached 81,866 states, more than the chart budget of 500, so the chart draws only the bug paths: 4 states and 4 arrows.
The chart has 0 label warnings.

## NoSpuriousConflictBlock breaks
The shortest path has 4 steps:
0. New note, no file yet
1. the person types in the note: New note, no file yet
2. the half-second save timer writes the note: File changed, window not told yet
3. the other Mac's offline edit arrives as a conflict version: Other Mac's conflict version waiting
4. the conflict sweep merges the conflict version [the window holds it back]: Outside edit held back

## Rules that hold
TypeOK, TypedTextKept, NoRepeatedText, OneLifecycleState, PurgeRespectsRetention, WindowMatchesDisk, NoFalseClose, NoUntouchedBlankFile, CloseAlwaysWorks, NoDeadlock

## Label warnings
No label has a warning.

## Arrows
| Label | From | To | TLA+ actions | Steps |
| --- | --- | --- | --- | --- |
| the person types in the note | New note, no file yet | New note, no file yet | Type | 1 |
| the half-second save timer writes the note | New note, no file yet | File changed, window not told yet | SaveFires | 1 |
| the other Mac's offline edit arrives as a conflict version | File changed, window not told yet | Other Mac's conflict version waiting | ExternalConflict | 1 |
| the conflict sweep merges the conflict version [the window holds it back] | Other Mac's conflict version waiting | Outside edit held back | ConflictSweep | 1 |
