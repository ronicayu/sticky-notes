# NotePersistence

TLC reached 394 states and 1603 steps. The chart draws 9 states and 32 arrows.
The chart has 0 label warnings.
The chart does not draw 317 steps that stay in one chart state.
The view hides 42 steps, so the chart does not draw them.

## NoSpuriousConflictBlock breaks
The shortest path has 5 steps:
0. File changed, window not told yet
1. the person types in the note: Typing, save pending
2. the half-second save timer writes the note: File changed, window not told yet
3. the person types in the note: Typing, save pending
4. the file watcher reports the change [the window holds it back]: Outside edit held back
5. the person switches to another window: Save pending, person in another window

## Rules that hold
TypeOK, TypedTextKept, OneLifecycleState, PurgeRespectsRetention, WindowMatchesDisk, NoDeadlock

## Label warnings
No label has a warning.

## Arrows
| Label | From | To | TLA+ actions | Steps |
| --- | --- | --- | --- | --- |
| the person quits the app | File changed, window not told yet | App quit, note on disk | Quit | 62 |
| the person leaves an empty note by closing it or switching away | File changed, window not told yet | Note file deleted | CloseNote, SwitchAway | 4 |
| the person types in the note | File changed, window not told yet | Typing, save pending | Type | 10 |
| the file watcher reports the change [the window shows it] | File changed, window not told yet | Note open, nothing pending | WatcherDelivers | 62 |
| the person quits the app | Note file deleted | App quit, note on disk | Quit | 2 |
| the person quits the app | Typing, save pending | App quit, note on disk | Quit | 48 |
| the person clicks the note's close button [the note has text] | Typing, save pending | Note in the archive | CloseNote | 48 |
| the half-second save timer writes the note | Typing, save pending | File changed, window not told yet | SaveFires | 48 |
| the person switches to another window | Typing, save pending | Save pending, person in another window | SwitchAway | 48 |
| the person grabs the note's title bar | Typing, save pending | Typing, save pending, caret out of the text | GrabTitleBar | 48 |
| the file watcher reports the change [the window holds it back] | Typing, save pending | Outside edit held back | WatcherDelivers | 14 |
| the person quits the app | Note open, nothing pending | App quit, note on disk | Quit | 62 |
| the person leaves an empty note by closing it or switching away | Note open, nothing pending | Note file deleted | CloseNote, SwitchAway | 4 |
| the person types in the note | Note open, nothing pending | Typing, save pending | Type | 10 |
| the person quits the app | Note in the archive | App quit, note on disk | Quit | 40 |
| the person clicks the note's close button [the note has text] | File changed, window not told yet | Note in the archive | CloseNote | 60 |
| the person clicks into the text | Save pending, person in another window | Typing, save pending | ClickIntoText | 48 |
| the person quits the app | Save pending, person in another window | App quit, note on disk | Quit | 48 |
| the person clicks the note's close button [the note has text] | Save pending, person in another window | Note in the archive | CloseNote | 48 |
| the half-second save timer writes the note | Save pending, person in another window | File changed, window not told yet | SaveFires | 48 |
| the file watcher reports the change [the window holds it back] | Save pending, person in another window | Outside edit held back | WatcherDelivers | 14 |
| the person clicks into the text | Typing, save pending, caret out of the text | Typing, save pending | ClickIntoText | 48 |
| the person quits the app | Typing, save pending, caret out of the text | App quit, note on disk | Quit | 48 |
| the person clicks the note's close button [the note has text] | Typing, save pending, caret out of the text | Note in the archive | CloseNote | 48 |
| the person switches to another window | Typing, save pending, caret out of the text | Save pending, person in another window | SwitchAway | 48 |
| the half-second save timer writes the note | Typing, save pending, caret out of the text | File changed, window not told yet | SaveFires | 48 |
| the file watcher reports the change [the window holds it back] | Typing, save pending, caret out of the text | Outside edit held back | WatcherDelivers | 14 |
| the person quits the app | Outside edit held back | App quit, note on disk | Quit | 42 |
| the person clicks the note's close button [the note has text] | Outside edit held back | Note in the archive | CloseNote | 42 |
| the half-second save timer writes the note | Outside edit held back | File changed, window not told yet | SaveFires | 42 |
| the person switches to another window | Outside edit held back | Save pending, person in another window | SwitchAway | 28 |
| the person clicks the note's close button [the note has text] | Note open, nothing pending | Note in the archive | CloseNote | 60 |
