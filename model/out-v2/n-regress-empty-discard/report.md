# NoteDocument

TLC reached 13,561 states, more than the chart budget of 500, so the chart draws only the bug paths: 3 states and 4 arrows.
The chart has 1 label warning.

## CloseAlwaysWorks breaks
The shortest path has 4 steps:
0. New note, no file yet
1. the person types in the note: New note, no file yet
2. the person deletes all the text: New note, no file yet
3. the half-second save timer writes the note: File changed, window not told yet
4. Obsidian or the other Mac appends a line to the file: File changed, window not told yet

## TypedTextKept breaks
The shortest path has 5 steps:
0. New note, no file yet
1. the person types in the note: New note, no file yet
2. the person deletes all the text: New note, no file yet
3. the half-second save timer writes the note: File changed, window not told yet
4. Obsidian or the other Mac appends a line to the file: File changed, window not told yet
5. the person clicks the note's close button: No note file, window closed

## Rules that hold
TypeOK, NoSpuriousConflictBlock, NoRepeatedText, OneLifecycleState, PurgeRespectsRetention, WindowMatchesDisk, NoFalseClose, NoUntouchedBlankFile, NoDeadlock

## Label warnings
- The tool joined 2 labels into "the person types in the note or the person deletes all the text" from "New note, no file yet" to "New note, no file yet". Give each arrow its own destination or its own label.

## Arrows
| Label | From | To | TLA+ actions | Steps |
| --- | --- | --- | --- | --- |
| the person types in the note or the person deletes all the text | New note, no file yet | New note, no file yet | EraseAll, Type | 2 |
| the half-second save timer writes the note | New note, no file yet | File changed, window not told yet | SaveFires | 1 |
| Obsidian or the other Mac appends a line to the file | File changed, window not told yet | File changed, window not told yet | ExternalEdit | 1 |
| the person clicks the note's close button | File changed, window not told yet | No note file, window closed | CloseNote | 1 |
