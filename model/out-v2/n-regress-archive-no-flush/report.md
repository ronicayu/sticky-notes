# NoteDocument

TLC reached 246 states and 880 steps. The chart draws 9 states and 27 arrows.
The chart has 1 label warning.
The chart does not draw 250 steps that stay in one chart state.
The view hides 124 steps, so the chart does not draw them.

## CloseAlwaysWorks breaks
The shortest path has 1 step:
0. New note, no file yet
1. the person types in the note: New note, no file yet

## TypedTextKept breaks
The shortest path has 2 steps:
0. New note, no file yet
1. the person types in the note: New note, no file yet
2. the person clicks the note's close button: No note file, window closed

## Rules that hold
TypeOK, NoSpuriousConflictBlock, NoRepeatedText, OneLifecycleState, PurgeRespectsRetention, WindowMatchesDisk, NoFalseClose, NoUntouchedBlankFile, NoDeadlock

## Label warnings
- The tool joined 2 labels into "the person clicks the note's close button or the person switches to another window" from "New note, no file yet" to "No note file, window closed". Give each arrow its own destination or its own label.

## Arrows
| Label | From | To | TLA+ actions | Steps |
| --- | --- | --- | --- | --- |
| the person quits the app | New note, no file yet | App quit, note on disk | Quit | 14 |
| the person clicks the note's close button or the person switches to another window | New note, no file yet | No note file, window closed | CloseNote, SwitchAway | 16 |
| the person types in the note | New note, no file yet | New note, no file yet | Type | 1 |
| the person quits the app | No note file, window closed | App quit, note on disk | Quit | 18 |
| the half-second save timer writes the note | New note, no file yet | File changed, window not told yet | SaveFires | 12 |
| the person quits the app | File changed, window not told yet | App quit, note on disk | Quit | 33 |
| the person clicks the note's close button | File changed, window not told yet | Note in the archive, window closed | CloseNote | 33 |
| the person types in the note | File changed, window not told yet | Typing, save pending | Type | 6 |
| the file watcher reports the change to the window [the window shows it] | File changed, window not told yet | Note open, nothing pending | WindowHears | 33 |
| the person quits the app | Note in the archive, window closed | App quit, note on disk | Quit | 72 |
| the person quits the app | Typing, save pending | App quit, note on disk | Quit | 14 |
| the person clicks the note's close button | Typing, save pending | Note in the archive, window closed | CloseNote | 14 |
| the half-second save timer writes the note | Typing, save pending | File changed, window not told yet | SaveFires | 14 |
| the person switches to another window | Typing, save pending | Save pending, person in another window | SwitchAway | 14 |
| the person grabs the note's title bar | Typing, save pending | Typing, save pending, caret out of the text | GrabTitleBar | 14 |
| the person quits the app | Note open, nothing pending | App quit, note on disk | Quit | 33 |
| the person clicks the note's close button | Note open, nothing pending | Note in the archive, window closed | CloseNote | 33 |
| the person types in the note | Note open, nothing pending | Typing, save pending | Type | 6 |
| the person clicks into the text | Save pending, person in another window | Typing, save pending | ClickIntoText | 14 |
| the person quits the app | Save pending, person in another window | App quit, note on disk | Quit | 14 |
| the person clicks the note's close button | Save pending, person in another window | Note in the archive, window closed | CloseNote | 14 |
| the half-second save timer writes the note | Save pending, person in another window | File changed, window not told yet | SaveFires | 14 |
| the person clicks into the text | Typing, save pending, caret out of the text | Typing, save pending | ClickIntoText | 14 |
| the person quits the app | Typing, save pending, caret out of the text | App quit, note on disk | Quit | 14 |
| the person clicks the note's close button | Typing, save pending, caret out of the text | Note in the archive, window closed | CloseNote | 14 |
| the person switches to another window | Typing, save pending, caret out of the text | Save pending, person in another window | SwitchAway | 14 |
| the half-second save timer writes the note | Typing, save pending, caret out of the text | File changed, window not told yet | SaveFires | 14 |
