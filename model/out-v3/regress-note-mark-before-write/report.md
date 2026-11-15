# NoteDocument

TLC reached 2,520 states, more than the chart budget of 500, so the chart draws only the bug paths: 8 states and 11 arrows.
The chart has 1 label warning.

## TypedTextKept breaks
The shortest path has 3 steps:
0. New note, no file yet
1. the person types in the note: New note with text, not written yet
2. the disk stops accepting writes: New note with text, not written yet
3. the person clicks the note's close button: No note file, window closed

## WindowMatchesDisk breaks
The shortest path has 7 steps:
0. New note, no file yet
1. the person types in the note: New note with text, not written yet
2. the half-second save timer writes the note: File changed, window not told yet
3. the person types in the note: Typing, save pending
4. the person switches to another window: Save pending, person in another window
5. the file watcher reports the change to the window [the window shows it]: Save pending, person in another window
6. the disk stops accepting writes: Disk not accepting writes, note open
7. the half-second save timer writes the note: Disk not accepting writes, note open

## CloseAlwaysWorks breaks
The shortest path has 7 steps:
0. New note, no file yet
1. the person types in the note: New note with text, not written yet
2. the half-second save timer writes the note: File changed, window not told yet
3. the person types in the note: Typing, save pending
4. the disk stops accepting writes: Disk not accepting writes, note open
5. the half-second save timer writes the note: Disk not accepting writes, note open
6. the file watcher reports the change to the window [the window holds it back]: Disk not accepting writes, note open
7. the disk accepts writes again: Outside edit held back

## NoSpuriousConflictBlock breaks
The shortest path has 8 steps:
0. New note, no file yet
1. the person types in the note: New note with text, not written yet
2. the half-second save timer writes the note: File changed, window not told yet
3. the person types in the note: Typing, save pending
4. the disk stops accepting writes: Disk not accepting writes, note open
5. the half-second save timer writes the note: Disk not accepting writes, note open
6. the person types in the note: Disk not accepting writes, note open
7. the file watcher reports the change to the window [the window holds it back]: Disk not accepting writes, note open
8. the person switches to another window: Disk not accepting writes, note open

## Rules that hold
TypeOK, NoRepeatedText, OneLifecycleState, PurgeRespectsRetention, NoFalseClose, NoUntouchedBlankFile, NoDeadlock

## Label warnings
- The tool joined 4 labels into "the half-second save timer writes the note or the file watcher reports the change to the window [the window holds it back] or the person types in the note or the person switches to another window" from "Disk not accepting writes, note open" to "Disk not accepting writes, note open". Give each arrow its own destination or its own label.

## Arrows
| Label | From | To | TLA+ actions | Steps |
| --- | --- | --- | --- | --- |
| the person types in the note | New note, no file yet | New note with text, not written yet | Type | 1 |
| the half-second save timer writes the note | New note with text, not written yet | File changed, window not told yet | SaveFires | 1 |
| the disk stops accepting writes | New note with text, not written yet | New note with text, not written yet | DiskFills | 1 |
| the person types in the note | File changed, window not told yet | Typing, save pending | Type | 1 |
| the person clicks the note's close button | New note with text, not written yet | No note file, window closed | CloseNote | 1 |
| the person switches to another window | Typing, save pending | Save pending, person in another window | SwitchAway | 1 |
| the disk stops accepting writes | Typing, save pending | Disk not accepting writes, note open | DiskFills | 1 |
| the file watcher reports the change to the window [the window shows it] | Save pending, person in another window | Save pending, person in another window | WindowHears | 1 |
| the half-second save timer writes the note or the file watcher reports the change to the window [the window holds it back] or the person types in the note or the person switches to another window | Disk not accepting writes, note open | Disk not accepting writes, note open | SaveFires, SwitchAway, Type, WindowHears | 6 |
| the disk stops accepting writes | Save pending, person in another window | Disk not accepting writes, note open | DiskFills | 1 |
| the disk accepts writes again | Disk not accepting writes, note open | Outside edit held back | DiskFrees | 1 |
