# NoteDocument

TLC reached 37,583 states, more than the chart budget of 500, so the chart draws only the bug paths: 5 states and 6 arrows.
The chart has 0 label warnings.

## NoSpuriousConflictBlock breaks
The shortest path has 6 steps:
0. New note, no file yet
1. the person types in the note: New note with text, not written yet
2. the half-second save timer writes the note: File changed, window not told yet
3. the person types in the note: Typing, save pending
4. the half-second save timer writes the note: File changed, window not told yet
5. Obsidian rewrites the file from an older copy: File changed, window not told yet
6. the person clicks the note's close button: Note in the archive, window closed

## Rules that hold
TypeOK, TypedTextKept, NoRepeatedText, OneLifecycleState, PurgeRespectsRetention, WindowMatchesDisk, NoFalseClose, NoUntouchedBlankFile, CloseAlwaysWorks, NoDeadlock

## Label warnings
No label has a warning.

## Arrows
| Label | From | To | TLA+ actions | Steps |
| --- | --- | --- | --- | --- |
| the person types in the note | New note, no file yet | New note with text, not written yet | Type | 1 |
| the half-second save timer writes the note | New note with text, not written yet | File changed, window not told yet | SaveFires | 1 |
| the person types in the note | File changed, window not told yet | Typing, save pending | Type | 1 |
| the half-second save timer writes the note | Typing, save pending | File changed, window not told yet | SaveFires | 1 |
| Obsidian rewrites the file from an older copy | File changed, window not told yet | File changed, window not told yet | ObsidianStaleRewrite | 1 |
| the person clicks the note's close button | File changed, window not told yet | Note in the archive, window closed | CloseNote | 1 |
