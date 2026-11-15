# NoteDocument

TLC reached 6,522 states, more than the chart budget of 500, so the chart draws only the bug paths: 5 states and 5 arrows.
The chart has 1 label warning.

## TypedTextKept breaks
The shortest path has 6 steps:
0. New note, no file yet
1. the person types in the note: New note with text, not written yet
2. the half-second save timer writes the note: File changed, window not told yet
3. the person types in the note: Typing, save pending
4. the person grabs the note's title bar: Typing, save pending, caret out of the text
5. Obsidian or the other Mac appends a line to the file: Typing, save pending, caret out of the text
6. the file watcher reports the change to the window [the window shows it]: Typing, save pending, caret out of the text

## CloseAlwaysWorks breaks
The shortest path has 6 steps:
0. New note, no file yet
1. the person types in the note: New note with text, not written yet
2. the half-second save timer writes the note: File changed, window not told yet
3. the person types in the note: Typing, save pending
4. the person grabs the note's title bar: Typing, save pending, caret out of the text
5. Obsidian or the other Mac appends a line to the file: Typing, save pending, caret out of the text
6. the file watcher reports the change to the window [the window shows it]: Typing, save pending, caret out of the text

## Rules that hold
TypeOK, NoSpuriousConflictBlock, NoRepeatedText, OneLifecycleState, PurgeRespectsRetention, WindowMatchesDisk, NoFalseClose, NoUntouchedBlankFile, NoDeadlock

## Label warnings
- The tool joined 2 labels into "Obsidian or the other Mac appends a line to the file or the file watcher reports the change to the window [the window shows it]" from "Typing, save pending, caret out of the text" to "Typing, save pending, caret out of the text". Give each arrow its own destination or its own label.

## Arrows
| Label | From | To | TLA+ actions | Steps |
| --- | --- | --- | --- | --- |
| the person types in the note | New note, no file yet | New note with text, not written yet | Type | 1 |
| the half-second save timer writes the note | New note with text, not written yet | File changed, window not told yet | SaveFires | 1 |
| the person types in the note | File changed, window not told yet | Typing, save pending | Type | 1 |
| the person grabs the note's title bar | Typing, save pending | Typing, save pending, caret out of the text | GrabTitleBar | 1 |
| Obsidian or the other Mac appends a line to the file or the file watcher reports the change to the window [the window shows it] | Typing, save pending, caret out of the text | Typing, save pending, caret out of the text | ExternalEdit, WindowHears | 2 |
