# NoteDocument

TLC reached 2,520 states, more than the chart budget of 500, so the chart draws only the bug paths: 7 states and 13 arrows.
The chart has 2 label warnings.

## TypedTextKept breaks
The shortest path has 3 steps:
0. New note, no file yet
1. the person types in the note: New note, no file yet
2. the disk stops accepting writes: New note, no file yet
3. the person clicks the note's close button: No note file, window closed

## WindowMatchesDisk breaks
The shortest path has 7 steps:
0. New note, no file yet
1. the person types in the note: New note, no file yet
2. the half-second save timer writes the note: File changed, window not told yet
3. the person types in the note: Typing, save pending
4. the person switches to another window: Save pending, person in another window
5. the file watcher reports the change to the window [the window shows it]: Save pending, person in another window
6. the disk stops accepting writes: Save pending, person in another window
7. the half-second save timer writes the note: Note open, nothing pending

## CloseAlwaysWorks breaks
The shortest path has 7 steps:
0. New note, no file yet
1. the person types in the note: New note, no file yet
2. the half-second save timer writes the note: File changed, window not told yet
3. the person types in the note: Typing, save pending
4. the disk stops accepting writes: Typing, save pending
5. the half-second save timer writes the note: File changed, window not told yet
6. the file watcher reports the change to the window [the window holds it back]: Outside edit held back
7. the disk accepts writes again: Outside edit held back

## NoSpuriousConflictBlock breaks
The shortest path has 8 steps:
0. New note, no file yet
1. the person types in the note: New note, no file yet
2. the half-second save timer writes the note: File changed, window not told yet
3. the person types in the note: Typing, save pending
4. the disk stops accepting writes: Typing, save pending
5. the half-second save timer writes the note: File changed, window not told yet
6. the person types in the note: Typing, save pending
7. the file watcher reports the change to the window [the window holds it back]: Outside edit held back
8. the person switches to another window: Save pending, person in another window

## Rules that hold
TypeOK, NoRepeatedText, OneLifecycleState, PurgeRespectsRetention, NoFalseClose, NoUntouchedBlankFile, NoDeadlock

## Label warnings
- The tool joined 2 labels into "the person types in the note or the disk stops accepting writes" from "New note, no file yet" to "New note, no file yet". Give each arrow its own destination or its own label.
- The tool joined 2 labels into "the file watcher reports the change to the window [the window shows it] or the disk stops accepting writes" from "Save pending, person in another window" to "Save pending, person in another window". Give each arrow its own destination or its own label.

## Arrows
| Label | From | To | TLA+ actions | Steps |
| --- | --- | --- | --- | --- |
| the person types in the note or the disk stops accepting writes | New note, no file yet | New note, no file yet | DiskFills, Type | 2 |
| the half-second save timer writes the note | New note, no file yet | File changed, window not told yet | SaveFires | 1 |
| the person types in the note | File changed, window not told yet | Typing, save pending | Type | 2 |
| the person clicks the note's close button | New note, no file yet | No note file, window closed | CloseNote | 1 |
| the person switches to another window | Typing, save pending | Save pending, person in another window | SwitchAway | 1 |
| the disk stops accepting writes | Typing, save pending | Typing, save pending | DiskFills | 1 |
| the file watcher reports the change to the window [the window shows it] or the disk stops accepting writes | Save pending, person in another window | Save pending, person in another window | DiskFills, WindowHears | 2 |
| the half-second save timer writes the note | Typing, save pending | File changed, window not told yet | SaveFires | 1 |
| the file watcher reports the change to the window [the window holds it back] | File changed, window not told yet | Outside edit held back | WindowHears | 1 |
| the disk accepts writes again | Outside edit held back | Outside edit held back | DiskFrees | 1 |
| the half-second save timer writes the note | Save pending, person in another window | Note open, nothing pending | SaveFires | 1 |
| the file watcher reports the change to the window [the window holds it back] | Typing, save pending | Outside edit held back | WindowHears | 1 |
| the person switches to another window | Outside edit held back | Save pending, person in another window | SwitchAway | 1 |
