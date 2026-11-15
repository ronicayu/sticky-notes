# NoteDocument

TLC reached 27,966 states, more than the chart budget of 500, so the chart draws only the bug paths: 4 states and 5 arrows.
The chart has 0 label warnings.

## NoSpuriousConflictBlock breaks
The shortest path has 5 steps:
0. New note, no file yet
1. the person types in the note: New note with text, not written yet
2. the half-second save timer writes the note: File changed, window not told yet
3. the person types in the note: Typing, save pending
4. Obsidian rewrites the note's properties, not its text: Typing, save pending
5. the half-second save timer writes the note: File changed, window not told yet

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
| Obsidian rewrites the note's properties, not its text | Typing, save pending | Typing, save pending | ExternalMetaWrite | 1 |
| the half-second save timer writes the note | Typing, save pending | File changed, window not told yet | SaveFires | 1 |
