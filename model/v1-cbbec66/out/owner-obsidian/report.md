# NotePersistence

TLC reached 1,258 states, more than the chart budget of 500, so the chart draws only the bug paths: 3 states and 5 arrows.
The chart has 0 label warnings.

## NoSpuriousConflictBlock breaks
The shortest path has 7 steps:
0. File changed, window not told yet
1. the person types in the note: Typing, save pending
2. the half-second save timer writes the note: File changed, window not told yet
3. the person types in the note: Typing, save pending
4. the half-second save timer writes the note: File changed, window not told yet
5. Obsidian rewrites the file from an older copy: File changed, window not told yet
6. the file watcher reports the change [the window holds it back]: Outside edit held back
7. the person switches to another window: File changed, window not told yet

## Rules that hold
TypeOK, TypedTextKept, OneLifecycleState, PurgeRespectsRetention, WindowMatchesDisk, NoDeadlock

## Label warnings
No label has a warning.

## Arrows
| Label | From | To | TLA+ actions | Steps |
| --- | --- | --- | --- | --- |
| the person types in the note | File changed, window not told yet | Typing, save pending | Type | 2 |
| the half-second save timer writes the note | Typing, save pending | File changed, window not told yet | SaveFires | 2 |
| Obsidian rewrites the file from an older copy | File changed, window not told yet | File changed, window not told yet | ObsidianStaleRewrite | 1 |
| the file watcher reports the change [the window holds it back] | File changed, window not told yet | Outside edit held back | WatcherDelivers | 1 |
| the person switches to another window | Outside edit held back | File changed, window not told yet | SwitchAway | 1 |
