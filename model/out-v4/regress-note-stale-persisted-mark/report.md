# NoteDocument

TLC reached 9,604 states, more than the chart budget of 500, so the chart draws only the bug paths: 7 states and 14 arrows.
The chart has 0 label warnings.

## NoRepeatedText breaks
The shortest path has 9 steps:
0. New note, no file yet
1. the person types in the note: New note with text, not written yet
2. the person grabs the note's title bar: New note with text, not written yet
3. the half-second save timer writes the note: File changed, window not told yet
4. Obsidian or the other Mac appends a line to the file: File changed, window not told yet
5. the file watcher reports the change to the window [the window shows it]: Note open, nothing pending
6. the person clicks into the text: Note open, nothing pending
7. the person types in the note: Typing, save pending
8. Obsidian rewrites the note's properties, not its text: Typing, save pending
9. the half-second save timer writes the note: File changed, window not told yet

## WindowMatchesDisk breaks
The shortest path has 9 steps:
0. New note, no file yet
1. the person types in the note: New note with text, not written yet
2. the half-second save timer writes the note: File changed, window not told yet
3. the person types in the note: Typing, save pending
4. the person switches to another window: Save pending, person in another window
5. the half-second save timer writes the note: File changed, window not told yet
6. Obsidian or the other Mac appends a line to the file: File changed, window not told yet
7. the file watcher reports the change to the window [the window shows it]: Note open, nothing pending
8. Obsidian rewrites the file from an older copy: File changed, window not told yet
9. the file watcher reports the change to the window [the window holds it back]: Outside edit held back

## Rules that hold
TypeOK, TypedTextKept, NoSpuriousConflictBlock, OneLifecycleState, PurgeRespectsRetention, NoFalseClose, NoUntouchedBlankFile, CloseAlwaysWorks, NoDeadlock

## Label warnings
No label has a warning.

## Arrows
| Label | From | To | TLA+ actions | Steps |
| --- | --- | --- | --- | --- |
| the person types in the note | New note, no file yet | New note with text, not written yet | Type | 1 |
| the half-second save timer writes the note | New note with text, not written yet | File changed, window not told yet | SaveFires | 2 |
| the person grabs the note's title bar | New note with text, not written yet | New note with text, not written yet | GrabTitleBar | 1 |
| the person types in the note | File changed, window not told yet | Typing, save pending | Type | 1 |
| the person switches to another window | Typing, save pending | Save pending, person in another window | SwitchAway | 1 |
| Obsidian or the other Mac appends a line to the file | File changed, window not told yet | File changed, window not told yet | ExternalEdit | 2 |
| the file watcher reports the change to the window [the window shows it] | File changed, window not told yet | Note open, nothing pending | WindowHears | 2 |
| the half-second save timer writes the note | Save pending, person in another window | File changed, window not told yet | SaveFires | 1 |
| the person clicks into the text | Note open, nothing pending | Note open, nothing pending | ClickIntoText | 1 |
| the person types in the note | Note open, nothing pending | Typing, save pending | Type | 1 |
| Obsidian rewrites the file from an older copy | Note open, nothing pending | File changed, window not told yet | ObsidianStaleRewrite | 1 |
| Obsidian rewrites the note's properties, not its text | Typing, save pending | Typing, save pending | ExternalMetaWrite | 1 |
| the half-second save timer writes the note | Typing, save pending | File changed, window not told yet | SaveFires | 1 |
| the file watcher reports the change to the window [the window holds it back] | File changed, window not told yet | Outside edit held back | WindowHears | 1 |
