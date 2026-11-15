# NoteDocument

TLC reached 383 states and 1501 steps. The chart draws 11 states and 38 arrows.
The chart has 2 label warnings.
The chart does not draw 504 steps that stay in one chart state.
The view hides 195 steps, so the chart does not draw them.

## Rules that hold
TypeOK, TypedTextKept, NoSpuriousConflictBlock, NoRepeatedText, OneLifecycleState, PurgeRespectsRetention, WindowMatchesDisk, NoFalseClose, NoUntouchedBlankFile, CloseAlwaysWorks, NoDeadlock

## Label warnings
- The tool joined 2 labels into "the person clicks the note's close button or the person switches to another window" from "New note, no file yet" to "No note file, window closed". Give each arrow its own destination or its own label.
- 2 arrows leave "Older own save kept as a conflict version" with the label "the conflict sweep merges the conflict version [the window shows it]" and go to different states: "File changed, window not told yet", "Note open, nothing pending". Tell them apart with a condition in brackets.

## Arrows
| Label | From | To | TLA+ actions | Steps |
| --- | --- | --- | --- | --- |
| the person quits the app | New note, no file yet | App quit, note on disk | Quit | 2 |
| the person clicks the note's close button or the person switches to another window | New note, no file yet | No note file, window closed | CloseNote, SwitchAway | 4 |
| the person types in the note | New note, no file yet | New note with text, not written yet | Type | 1 |
| the person quits the app | No note file, window closed | App quit, note on disk | Quit | 2 |
| the person quits the app | New note with text, not written yet | App quit, note on disk | Quit | 12 |
| the person clicks the note's close button | New note with text, not written yet | Note in the archive, window closed | CloseNote | 12 |
| the half-second save timer writes the note | New note with text, not written yet | File changed, window not told yet | SaveFires | 12 |
| the person quits the app | Note in the archive, window closed | App quit, note on disk | Quit | 132 |
| the person quits the app | File changed, window not told yet | App quit, note on disk | Quit | 33 |
| the person clicks the note's close button | File changed, window not told yet | Note in the archive, window closed | CloseNote | 33 |
| the person types in the note | File changed, window not told yet | Typing, save pending | Type | 6 |
| the file watcher reports the change to the window [the window shows it] | File changed, window not told yet | Note open, nothing pending | WindowHears | 33 |
| the person quits the app | Typing, save pending | App quit, note on disk | Quit | 14 |
| the person clicks the note's close button | Typing, save pending | Note in the archive, window closed | CloseNote | 14 |
| the half-second save timer writes the note | Typing, save pending | File changed, window not told yet | SaveFires | 14 |
| the person switches to another window | Typing, save pending | Save pending, person in another window | SwitchAway | 14 |
| the person grabs the note's title bar | Typing, save pending | Typing, save pending, caret out of the text | GrabTitleBar | 14 |
| the person quits the app | Note open, nothing pending | App quit, note on disk | Quit | 33 |
| the person clicks the note's close button | Note open, nothing pending | Note in the archive, window closed | CloseNote | 33 |
| the person types in the note | Note open, nothing pending | Typing, save pending | Type | 6 |
| iCloud keeps an older save as a conflict version | File changed, window not told yet | Older own save kept as a conflict version | ICloudSelfConflict | 21 |
| the person clicks into the text | Save pending, person in another window | Typing, save pending | ClickIntoText | 14 |
| the person quits the app | Save pending, person in another window | App quit, note on disk | Quit | 14 |
| the person clicks the note's close button | Save pending, person in another window | Note in the archive, window closed | CloseNote | 14 |
| the half-second save timer writes the note | Save pending, person in another window | File changed, window not told yet | SaveFires | 14 |
| the person clicks into the text | Typing, save pending, caret out of the text | Typing, save pending | ClickIntoText | 14 |
| the person quits the app | Typing, save pending, caret out of the text | App quit, note on disk | Quit | 14 |
| the person clicks the note's close button | Typing, save pending, caret out of the text | Note in the archive, window closed | CloseNote | 14 |
| the person switches to another window | Typing, save pending, caret out of the text | Save pending, person in another window | SwitchAway | 14 |
| the half-second save timer writes the note | Typing, save pending, caret out of the text | File changed, window not told yet | SaveFires | 14 |
| iCloud keeps an older save as a conflict version | Note open, nothing pending | Older own save kept as a conflict version | ICloudSelfConflict | 21 |
| the conflict sweep merges the conflict version [the window shows it] | Older own save kept as a conflict version | File changed, window not told yet | ConflictSweep | 39 |
| the person quits the app | Older own save kept as a conflict version | App quit, note on disk | Quit | 66 |
| the person clicks the note's close button | Older own save kept as a conflict version | Note in the archive, window closed | CloseNote | 66 |
| iCloud keeps an older save as a conflict version | Typing, save pending | Older own save kept as a conflict version | ICloudSelfConflict | 4 |
| the conflict sweep merges the conflict version [the window shows it] | Older own save kept as a conflict version | Note open, nothing pending | ConflictSweep | 27 |
| iCloud keeps an older save as a conflict version | Save pending, person in another window | Older own save kept as a conflict version | ICloudSelfConflict | 4 |
| iCloud keeps an older save as a conflict version | Typing, save pending, caret out of the text | Older own save kept as a conflict version | ICloudSelfConflict | 4 |
