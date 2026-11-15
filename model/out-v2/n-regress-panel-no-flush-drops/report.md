# NoteDocument

TLC reached 16,133 states, more than the chart budget of 500, so the chart draws only the bug paths: 5 states and 5 arrows.
The chart has 0 label warnings.

## TypedTextKept breaks
The shortest path has 5 steps:
0. New note, no file yet
1. the person types in the note: New note, no file yet
2. the half-second save timer writes the note: File changed, window not told yet
3. the person types in the note: Typing, save pending
4. the other Mac archives, trashes or deletes the file: Window open, note moved to the archive
5. the desk closes the window of a note that is gone: Note in the archive, window closed

## Rules that hold
TypeOK, NoSpuriousConflictBlock, NoRepeatedText, OneLifecycleState, PurgeRespectsRetention, WindowMatchesDisk, NoFalseClose, NoUntouchedBlankFile, CloseAlwaysWorks, NoDeadlock

## Label warnings
No label has a warning.

## Arrows
| Label | From | To | TLA+ actions | Steps |
| --- | --- | --- | --- | --- |
| the person types in the note | New note, no file yet | New note, no file yet | Type | 1 |
| the half-second save timer writes the note | New note, no file yet | File changed, window not told yet | SaveFires | 1 |
| the person types in the note | File changed, window not told yet | Typing, save pending | Type | 1 |
| the other Mac archives, trashes or deletes the file | Typing, save pending | Window open, note moved to the archive | ExternalMove | 1 |
| the desk closes the window of a note that is gone | Window open, note moved to the archive | Note in the archive, window closed | Reconcile | 1 |
