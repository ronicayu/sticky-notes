# NotePersistence

TLC reached 13,489 states, more than the chart budget of 500, so the chart draws only the bug paths: 7 states and 10 arrows.
The chart has 0 label warnings.

## TypedTextKept breaks
The shortest path has 2 steps:
0. File changed, window not told yet
1. the other Mac's edit arrives as a conflict version: Other Mac's conflict version waiting
2. the person leaves an empty note by closing it or switching away: Note file deleted

## NoSpuriousConflictBlock breaks
The shortest path has 2 steps:
0. File changed, window not told yet
1. the other Mac's edit arrives as a conflict version: Other Mac's conflict version waiting
2. the conflict sweep merges the conflict version [the window holds it back]: Outside edit held back

## WindowMatchesDisk breaks
The shortest path has 10 steps:
0. File changed, window not told yet
1. the person types in the note: Typing, save pending
2. the half-second save timer writes the note: File changed, window not told yet
3. the person types in the note: Typing, save pending
4. the person switches to another window: Save pending, person in another window
5. the half-second save timer writes the note: File changed, window not told yet
6. iCloud keeps an older save as a conflict version: Older own save kept as a conflict version
7. the conflict sweep merges the conflict version [the window shows it]: File changed, window not told yet
8. the other Mac's edit arrives as a conflict version: Other Mac's conflict version waiting
9. the conflict sweep merges the conflict version [the window holds it back]: Outside edit held back
10. the file watcher reports the change [it replaces the held-back edit]: Outside edit held back

## Rules that hold
TypeOK, OneLifecycleState, PurgeRespectsRetention, NoDeadlock

## Label warnings
No label has a warning.

## Arrows
| Label | From | To | TLA+ actions | Steps |
| --- | --- | --- | --- | --- |
| the person types in the note | File changed, window not told yet | Typing, save pending | Type | 2 |
| the other Mac's edit arrives as a conflict version | File changed, window not told yet | Other Mac's conflict version waiting | ExternalConflict | 2 |
| the half-second save timer writes the note | Typing, save pending | File changed, window not told yet | SaveFires | 1 |
| the person leaves an empty note by closing it or switching away | Other Mac's conflict version waiting | Note file deleted | SwitchAway | 1 |
| the conflict sweep merges the conflict version [the window holds it back] | Other Mac's conflict version waiting | Outside edit held back | ConflictSweep | 2 |
| the person switches to another window | Typing, save pending | Save pending, person in another window | SwitchAway | 1 |
| the half-second save timer writes the note | Save pending, person in another window | File changed, window not told yet | SaveFires | 1 |
| iCloud keeps an older save as a conflict version | File changed, window not told yet | Older own save kept as a conflict version | ICloudSelfConflict | 1 |
| the conflict sweep merges the conflict version [the window shows it] | Older own save kept as a conflict version | File changed, window not told yet | ConflictSweep | 1 |
| the file watcher reports the change [it replaces the held-back edit] | Outside edit held back | Outside edit held back | WatcherDelivers | 1 |
