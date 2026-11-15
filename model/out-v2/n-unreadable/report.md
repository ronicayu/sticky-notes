# NoteDocument

TLC reached 3,121 states, more than the chart budget of 500, so the chart draws only the bug paths: 3 states and 3 arrows.
The chart has 0 label warnings.

## CloseAlwaysWorks breaks
The shortest path has 3 steps:
0. New note, no file yet
1. the person types in the note: New note, no file yet
2. the half-second save timer writes the note: File changed, window not told yet
3. iCloud hides or locks the file for a while: Note file cannot be read

## Rules that hold
TypeOK, TypedTextKept, NoSpuriousConflictBlock, NoRepeatedText, OneLifecycleState, PurgeRespectsRetention, WindowMatchesDisk, NoFalseClose, NoUntouchedBlankFile, NoDeadlock

## Label warnings
No label has a warning.

## Arrows
| Label | From | To | TLA+ actions | Steps |
| --- | --- | --- | --- | --- |
| the person types in the note | New note, no file yet | New note, no file yet | Type | 1 |
| the half-second save timer writes the note | New note, no file yet | File changed, window not told yet | SaveFires | 1 |
| iCloud hides or locks the file for a while | File changed, window not told yet | Note file cannot be read | FileVanishes | 1 |
