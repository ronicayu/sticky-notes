# NotePersistence

TLC reached 18,181 states, more than the chart budget of 500, so the chart draws only the bug paths: 6 states and 10 arrows.
The chart has 0 label warnings.

## TypedTextKept breaks
The shortest path has 2 steps:
0. File changed, window not told yet
1. Obsidian or the other Mac edits the file: File changed, window not told yet
2. the person leaves an empty note by closing it or switching away: Note file deleted

## NoSpuriousConflictBlock breaks
The shortest path has 5 steps:
0. File changed, window not told yet
1. the person types in the note: Typing, save pending
2. the half-second save timer writes the note: File changed, window not told yet
3. Obsidian or the other Mac edits the file: File changed, window not told yet
4. the file watcher reports the change [the window holds it back]: Outside edit held back
5. the person switches to another window: File changed, window not told yet

## WindowMatchesDisk breaks
The shortest path has 7 steps:
0. File changed, window not told yet
1. the person types in the note: Typing, save pending
2. the person switches to another window: Save pending, person in another window
3. the half-second save timer writes the note: File changed, window not told yet
4. Obsidian or the other Mac edits the file: File changed, window not told yet
5. the file watcher reports the change [the window shows it]: Note open, nothing pending
6. Obsidian rewrites the file from an older copy: File changed, window not told yet
7. the file watcher reports the change [the window holds it back]: Outside edit held back

## Rules that hold
TypeOK, OneLifecycleState, PurgeRespectsRetention, NoDeadlock

## Label warnings
No label has a warning.

## Arrows
| Label | From | To | TLA+ actions | Steps |
| --- | --- | --- | --- | --- |
| Obsidian or the other Mac edits the file | File changed, window not told yet | File changed, window not told yet | ExternalEdit | 3 |
| the person types in the note | File changed, window not told yet | Typing, save pending | Type | 1 |
| the person leaves an empty note by closing it or switching away | File changed, window not told yet | Note file deleted | SwitchAway | 1 |
| the half-second save timer writes the note | Typing, save pending | File changed, window not told yet | SaveFires | 1 |
| the person switches to another window | Typing, save pending | Save pending, person in another window | SwitchAway | 1 |
| the half-second save timer writes the note | Save pending, person in another window | File changed, window not told yet | SaveFires | 1 |
| the file watcher reports the change [the window holds it back] | File changed, window not told yet | Outside edit held back | WatcherDelivers | 2 |
| the file watcher reports the change [the window shows it] | File changed, window not told yet | Note open, nothing pending | WatcherDelivers | 1 |
| the person switches to another window | Outside edit held back | File changed, window not told yet | SwitchAway | 1 |
| Obsidian rewrites the file from an older copy | Note open, nothing pending | File changed, window not told yet | ObsidianStaleRewrite | 1 |
