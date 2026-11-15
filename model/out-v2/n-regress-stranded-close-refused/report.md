# NoteDocument

TLC reached 18,709 states, more than the chart budget of 500, so the chart draws only the bug paths: 4 states and 5 arrows.
The chart has 0 label warnings.

## CloseAlwaysWorks breaks
The shortest path has 5 steps:
0. New note, no file yet
1. the person types in the note: New note, no file yet
2. the half-second save timer writes the note: File changed, window not told yet
3. the person types in the note: Typing, save pending
4. the other Mac archives, trashes or deletes the file: Window open, note file gone
5. iCloud leaves a download placeholder in the notes folders: Window open, note file gone

## Rules that hold
TypeOK, TypedTextKept, NoSpuriousConflictBlock, NoRepeatedText, OneLifecycleState, PurgeRespectsRetention, WindowMatchesDisk, NoFalseClose, NoUntouchedBlankFile, NoDeadlock

## Label warnings
No label has a warning.

## Arrows
| Label | From | To | TLA+ actions | Steps |
| --- | --- | --- | --- | --- |
| the person types in the note | New note, no file yet | New note, no file yet | Type | 1 |
| the half-second save timer writes the note | New note, no file yet | File changed, window not told yet | SaveFires | 1 |
| the person types in the note | File changed, window not told yet | Typing, save pending | Type | 1 |
| the other Mac archives, trashes or deletes the file | Typing, save pending | Window open, note file gone | ExternalMove | 1 |
| iCloud leaves a download placeholder in the notes folders | Window open, note file gone | Window open, note file gone | PlaceholderAppears | 1 |
