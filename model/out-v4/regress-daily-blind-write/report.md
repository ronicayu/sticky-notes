# DailyDocument

TLC reached 4,393 states, more than the chart budget of 500, so the chart draws only the bug paths: 11 states and 11 arrows.
The chart has 0 label warnings.
The chart does not draw 3 steps that stay in one chart state.
The step the clock passes midnight changes This Mac and iCloud at the same time.
The step the file watcher reports the change changes This Mac and iCloud at the same time.

## DailyTextKept breaks
The shortest path has 9 steps:
0. This Mac Showing today's note (day 1), iCloud Day 1, no day-2 file
1. the person clicks into the daily note: This Mac Showing today's note (day 1), iCloud Day 1, no day-2 file
2. the clock passes midnight: This Mac Showing yesterday's note, iCloud No file for today in iCloud
3. the midnight timer or wake switches to today: This Mac Today's note shown, file not created, iCloud No file for today in iCloud
4. the person types in the daily note: This Mac Typing, save pending, iCloud No file for today in iCloud
5. the other Mac creates today's file offline: This Mac Typing, save pending, iCloud The other Mac created today's file offline
6. iCloud uploads the other Mac's new file: This Mac Typing, save pending, iCloud One file for today in iCloud
7. iCloud downloads the newer file to this Mac: This Mac Typing, save pending, iCloud One file for today in iCloud
8. the save timer writes the daily note: This Mac Today's note open, iCloud One file for today in iCloud
9. iCloud uploads this Mac's file: This Mac Today's note open, iCloud One file for today in iCloud

## NoSpuriousConflictBlock breaks
The shortest path has 10 steps:
0. This Mac Showing today's note (day 1), iCloud Day 1, no day-2 file
1. the person clicks into the daily note: This Mac Showing today's note (day 1), iCloud Day 1, no day-2 file
2. the clock passes midnight: This Mac Showing yesterday's note, iCloud No file for today in iCloud
3. the midnight timer or wake switches to today: This Mac Today's note shown, file not created, iCloud No file for today in iCloud
4. the person types in the daily note: This Mac Typing, save pending, iCloud No file for today in iCloud
5. the save timer writes the daily note: This Mac Today's note open, iCloud No file for today in iCloud
6. the person fixes a typo in today's line: This Mac Typing, save pending, iCloud No file for today in iCloud
7. the other Mac creates today's file offline: This Mac Typing, save pending, iCloud The other Mac created today's file offline
8. iCloud uploads the other Mac's new file: This Mac Typing, save pending, iCloud One file for today in iCloud
9. iCloud uploads this Mac's file: This Mac Typing, save pending, iCloud Today's file plus a numbered duplicate
10. the file watcher reports the change: This Mac Outside edit held back, iCloud One file for today in iCloud

## Rules that hold
TypeOK, ClockNeverCreates, DuplicateOnlyFromTwoPeople, RightDay, NoRepeatedText, WindowMatchesDisk, ConflictVersionsMerged, NoDeadlock

## Label warnings
No label has a warning.

## Arrows
| Label | From | To | TLA+ actions | Steps |
| --- | --- | --- | --- | --- |
| the clock passes midnight | This Mac: Showing today's note (day 1) | This Mac: Showing yesterday's note | Midnight | 1 |
| the midnight timer or wake switches to today | This Mac: Showing yesterday's note | This Mac: Today's note shown, file not created | Rollover | 1 |
| the person types in the daily note | This Mac: Today's note shown, file not created | This Mac: Typing, save pending | Type | 1 |
| the save timer writes the daily note [when No file for today in iCloud or One file for today in iCloud] | This Mac: Typing, save pending | This Mac: Today's note open | SaveFires | 2 |
| the person fixes a typo in today's line [when No file for today in iCloud] | This Mac: Today's note open | This Mac: Typing, save pending | RewriteTypo | 1 |
| the file watcher reports the change [when Today's file plus a numbered duplicate] | This Mac: Typing, save pending | This Mac: Outside edit held back | WatcherDelivers | 1 |
| the clock passes midnight | iCloud: Day 1, no day-2 file | iCloud: No file for today in iCloud | Midnight | 1 |
| the other Mac creates today's file offline [when Typing, save pending] | iCloud: No file for today in iCloud | iCloud: The other Mac created today's file offline | BCreatesOffline | 2 |
| iCloud uploads the other Mac's new file | iCloud: The other Mac created today's file offline | iCloud: One file for today in iCloud | BUploads | 2 |
| iCloud uploads this Mac's file [when Typing, save pending] | iCloud: One file for today in iCloud | iCloud: Today's file plus a numbered duplicate | Upload | 1 |
| the file watcher reports the change | iCloud: Today's file plus a numbered duplicate | iCloud: One file for today in iCloud | WatcherDelivers | 1 |
