# NoteDocument

TLC reached 13,703 states, more than the chart budget of 500, so the chart draws only the bug paths: 7 states and 15 arrows.
The chart has 2 label warnings.

## NoRepeatedText breaks
The shortest path has 9 steps:
0. New note, no file yet
1. the person types in the note: New note, no file yet
2. the person grabs the note's title bar: New note, no file yet
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
1. the person types in the note: New note, no file yet
2. the half-second save timer writes the note: File changed, window not told yet
3. the person types in the note: Typing, save pending
4. the person switches to another window: Save pending, person in another window
5. the half-second save timer writes the note: File changed, window not told yet
6. Obsidian or the other Mac appends a line to the file: File changed, window not told yet
7. the file watcher reports the change to the window [the window shows it]: Note open, nothing pending
8. Obsidian rewrites the file from an older copy: File changed, window not told yet
9. the file watcher reports the change to the window [the window holds it back]: Outside edit held back

## NoSpuriousConflictBlock breaks
The shortest path has 12 steps:
0. New note, no file yet
1. the person types in the note: New note, no file yet
2. the half-second save timer writes the note: File changed, window not told yet
3. the person types in the note: Typing, save pending
4. the person grabs the note's title bar: Typing, save pending, caret out of the text
5. the half-second save timer writes the note: File changed, window not told yet
6. Obsidian rewrites the file from an older copy: File changed, window not told yet
7. Obsidian or the other Mac appends a line to the file: File changed, window not told yet
8. the file watcher reports the change to the window [the window shows it]: Note open, nothing pending
9. the person clicks into the text: Note open, nothing pending
10. the person types in the note: Typing, save pending
11. Obsidian rewrites the note's properties, not its text: Typing, save pending
12. the half-second save timer writes the note: File changed, window not told yet

## Rules that hold
TypeOK, TypedTextKept, OneLifecycleState, PurgeRespectsRetention, NoFalseClose, NoUntouchedBlankFile, CloseAlwaysWorks, NoDeadlock

## Label warnings
- The tool joined 2 labels into "the person types in the note or the person grabs the note's title bar" from "New note, no file yet" to "New note, no file yet". Give each arrow its own destination or its own label.
- The tool joined 2 labels into "Obsidian or the other Mac appends a line to the file or Obsidian rewrites the file from an older copy" from "File changed, window not told yet" to "File changed, window not told yet". Give each arrow its own destination or its own label.

## Arrows
| Label | From | To | TLA+ actions | Steps |
| --- | --- | --- | --- | --- |
| the person types in the note or the person grabs the note's title bar | New note, no file yet | New note, no file yet | GrabTitleBar, Type | 2 |
| the half-second save timer writes the note | New note, no file yet | File changed, window not told yet | SaveFires | 2 |
| the person types in the note | File changed, window not told yet | Typing, save pending | Type | 1 |
| the person switches to another window | Typing, save pending | Save pending, person in another window | SwitchAway | 1 |
| the person grabs the note's title bar | Typing, save pending | Typing, save pending, caret out of the text | GrabTitleBar | 1 |
| Obsidian or the other Mac appends a line to the file or Obsidian rewrites the file from an older copy | File changed, window not told yet | File changed, window not told yet | ExternalEdit, ObsidianStaleRewrite | 4 |
| the file watcher reports the change to the window [the window shows it] | File changed, window not told yet | Note open, nothing pending | WindowHears | 3 |
| the half-second save timer writes the note | Save pending, person in another window | File changed, window not told yet | SaveFires | 1 |
| the half-second save timer writes the note | Typing, save pending, caret out of the text | File changed, window not told yet | SaveFires | 1 |
| the person clicks into the text | Note open, nothing pending | Note open, nothing pending | ClickIntoText | 2 |
| the person types in the note | Note open, nothing pending | Typing, save pending | Type | 2 |
| Obsidian rewrites the file from an older copy | Note open, nothing pending | File changed, window not told yet | ObsidianStaleRewrite | 1 |
| Obsidian rewrites the note's properties, not its text | Typing, save pending | Typing, save pending | ExternalMetaWrite | 2 |
| the half-second save timer writes the note | Typing, save pending | File changed, window not told yet | SaveFires | 2 |
| the file watcher reports the change to the window [the window holds it back] | File changed, window not told yet | Outside edit held back | WindowHears | 1 |
