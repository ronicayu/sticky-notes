# NoteDocument

TLC reached 23,523 states, more than the chart budget of 500, so the chart draws only the bug paths: 5 states and 8 arrows.
The chart has 0 label warnings.

## NoFalseClose breaks
The shortest path has 4 steps:
0. New note, no file yet
1. the person types in the note: New note, no file yet
2. the half-second save timer writes the note: File changed, window not told yet
3. iCloud hides or locks the file for a while: Note file cannot be read
4. the desk closes the window of a note that is gone: Note on disk, window closed

## TypedTextKept breaks
The shortest path has 5 steps:
0. New note, no file yet
1. the person types in the note: New note, no file yet
2. the half-second save timer writes the note: File changed, window not told yet
3. the person types in the note: Typing, save pending
4. iCloud hides or locks the file for a while: Note file cannot be read
5. the desk closes the window of a note that is gone: Note on disk, window closed

## CloseAlwaysWorks breaks
The shortest path has 7 steps:
0. New note, no file yet
1. the person types in the note: New note, no file yet
2. the half-second save timer writes the note: File changed, window not told yet
3. the person types in the note: Typing, save pending
4. iCloud hides or locks the file for a while: Note file cannot be read
5. the desk closes the window of a note that is gone: Note on disk, window closed
6. iCloud shows the file again: Note on disk, window closed
7. the desk opens a window for a note that is back: File changed, window not told yet

## Rules that hold
TypeOK, NoSpuriousConflictBlock, NoRepeatedText, OneLifecycleState, PurgeRespectsRetention, WindowMatchesDisk, NoUntouchedBlankFile, NoDeadlock

## Label warnings
No label has a warning.

## Arrows
| Label | From | To | TLA+ actions | Steps |
| --- | --- | --- | --- | --- |
| the person types in the note | New note, no file yet | New note, no file yet | Type | 1 |
| the half-second save timer writes the note | New note, no file yet | File changed, window not told yet | SaveFires | 1 |
| iCloud hides or locks the file for a while | File changed, window not told yet | Note file cannot be read | FileVanishes | 1 |
| the person types in the note | File changed, window not told yet | Typing, save pending | Type | 1 |
| the desk closes the window of a note that is gone | Note file cannot be read | Note on disk, window closed | Reconcile | 2 |
| iCloud hides or locks the file for a while | Typing, save pending | Note file cannot be read | FileVanishes | 1 |
| iCloud shows the file again | Note on disk, window closed | Note on disk, window closed | FileReturns | 1 |
| the desk opens a window for a note that is back | Note on disk, window closed | File changed, window not told yet | Reconcile | 1 |
