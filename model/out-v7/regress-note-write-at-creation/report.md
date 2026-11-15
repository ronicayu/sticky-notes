# NoteDocument

TLC reached 263 states and 971 steps. The chart draws 8 states and 25 arrows.
The chart has 2 label warnings.
The chart does not draw 251 steps that stay in one chart state.
The view hides 127 steps, so the chart does not draw them.

## NoUntouchedBlankFile breaks
The shortest path has 0 steps:
0. File changed, window not told yet

## Rules that hold
TypeOK, TypedTextKept, NoSpuriousConflictBlock, NoRepeatedText, OneLifecycleState, PurgeRespectsRetention, WindowMatchesDisk, NoFalseClose, CloseAlwaysWorks, NoDeadlock

## Label warnings
- The tool joined 2 labels into "the person clicks the note's close button or the person switches to another window" from "File changed, window not told yet" to "Note in the Trash, window closed". Give each arrow its own destination or its own label.
- The tool joined 2 labels into "the person clicks the note's close button or the person switches to another window" from "Note open, nothing pending" to "Note in the Trash, window closed". Give each arrow its own destination or its own label.

## Arrows
| Label | From | To | TLA+ actions | Steps |
| --- | --- | --- | --- | --- |
| the person quits the app | File changed, window not told yet | App quit, note on disk | Quit | 35 |
| the person clicks the note's close button or the person switches to another window | File changed, window not told yet | Note in the Trash, window closed | CloseNote, SwitchAway | 4 |
| the person types in the note | File changed, window not told yet | Typing, save pending | Type | 7 |
| the file watcher reports the change to the window [the window shows it] | File changed, window not told yet | Note open, nothing pending | WindowHears | 35 |
| the person quits the app | Note in the Trash, window closed | App quit, note on disk | Quit | 4 |
| the person quits the app | Typing, save pending | App quit, note on disk | Quit | 22 |
| the person clicks the note's close button | Typing, save pending | Note in the archive, window closed | CloseNote | 22 |
| the half-second save timer writes the note | Typing, save pending | File changed, window not told yet | SaveFires | 22 |
| the person switches to another window | Typing, save pending | Save pending, person in another window | SwitchAway | 22 |
| the person grabs the note's title bar | Typing, save pending | Typing, save pending, caret out of the text | GrabTitleBar | 22 |
| the person quits the app | Note open, nothing pending | App quit, note on disk | Quit | 35 |
| the person clicks the note's close button or the person switches to another window | Note open, nothing pending | Note in the Trash, window closed | CloseNote, SwitchAway | 4 |
| the person types in the note | Note open, nothing pending | Typing, save pending | Type | 7 |
| the person quits the app | Note in the archive, window closed | App quit, note on disk | Quit | 88 |
| the person clicks the note's close button | File changed, window not told yet | Note in the archive, window closed | CloseNote | 33 |
| the person clicks into the text | Save pending, person in another window | Typing, save pending | ClickIntoText | 22 |
| the person quits the app | Save pending, person in another window | App quit, note on disk | Quit | 22 |
| the person clicks the note's close button | Save pending, person in another window | Note in the archive, window closed | CloseNote | 22 |
| the half-second save timer writes the note | Save pending, person in another window | File changed, window not told yet | SaveFires | 22 |
| the person clicks into the text | Typing, save pending, caret out of the text | Typing, save pending | ClickIntoText | 22 |
| the person quits the app | Typing, save pending, caret out of the text | App quit, note on disk | Quit | 22 |
| the person clicks the note's close button | Typing, save pending, caret out of the text | Note in the archive, window closed | CloseNote | 22 |
| the person switches to another window | Typing, save pending, caret out of the text | Save pending, person in another window | SwitchAway | 22 |
| the half-second save timer writes the note | Typing, save pending, caret out of the text | File changed, window not told yet | SaveFires | 22 |
| the person clicks the note's close button | Note open, nothing pending | Note in the archive, window closed | CloseNote | 33 |
