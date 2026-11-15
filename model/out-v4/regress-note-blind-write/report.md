# NoteDocument

TLC reached 7,678 states, more than the chart budget of 500, so the chart draws only the bug paths: 4 states and 4 arrows.
The chart has 0 label warnings.

## CloseAlwaysWorks breaks
The shortest path has 3 steps:
0. New note, no file yet
1. the person types in the note: New note with text, not written yet
2. the half-second save timer writes the note: File changed, window not told yet
3. Obsidian or the other Mac appends a line to the file: File changed, window not told yet

## TypedTextKept breaks
The shortest path has 4 steps:
0. New note, no file yet
1. the person types in the note: New note with text, not written yet
2. the half-second save timer writes the note: File changed, window not told yet
3. Obsidian or the other Mac appends a line to the file: File changed, window not told yet
4. the person clicks the note's close button: Note in the archive, window closed

## Rules that hold
TypeOK, NoSpuriousConflictBlock, NoRepeatedText, OneLifecycleState, PurgeRespectsRetention, WindowMatchesDisk, NoFalseClose, NoUntouchedBlankFile, NoDeadlock

## Label warnings
No label has a warning.

## Arrows
| Label | From | To | TLA+ actions | Steps |
| --- | --- | --- | --- | --- |
| the person types in the note | New note, no file yet | New note with text, not written yet | Type | 1 |
| the half-second save timer writes the note | New note with text, not written yet | File changed, window not told yet | SaveFires | 1 |
| Obsidian or the other Mac appends a line to the file | File changed, window not told yet | File changed, window not told yet | ExternalEdit | 1 |
| the person clicks the note's close button | File changed, window not told yet | Note in the archive, window closed | CloseNote | 1 |
