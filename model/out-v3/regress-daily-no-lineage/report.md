# DailyDocument

TLC reached 9,561 states, more than the chart budget of 500, so the chart draws only the bug paths: 9 states and 9 arrows.
The chart has 0 label warnings.
The chart does not draw 1 steps that stay in one chart state.
The step the clock passes midnight changes This Mac and iCloud at the same time.
The step the file watcher reports the change changes This Mac and iCloud at the same time.

## NoSpuriousConflictBlock breaks
The shortest path has 9 steps:
0. This Mac Showing today's note (day 1), iCloud Day 1, no day-2 file
1. the person clicks into the daily note: This Mac Showing today's note (day 1), iCloud Day 1, no day-2 file
2. the clock passes midnight: This Mac Showing yesterday's note, iCloud No file for today in iCloud
3. the midnight timer or wake switches to today: This Mac Today's note shown, file not created, iCloud No file for today in iCloud
4. the person types in the daily note: This Mac Typing, save pending, iCloud No file for today in iCloud
5. the save timer writes the daily note: This Mac Today's note open, iCloud No file for today in iCloud
6. the person fixes a typo in today's line: This Mac Typing, save pending, iCloud No file for today in iCloud
7. the save timer writes the daily note: This Mac Today's note open, iCloud No file for today in iCloud
8. iCloud keeps an older save of this Mac as a conflict version: This Mac Today's note open, iCloud A conflict version of today's file is waiting
9. the file watcher reports the change: This Mac Outside edit held back, iCloud No file for today in iCloud

## Rules that hold
TypeOK, ClockNeverCreates, DuplicateOnlyFromTwoPeople, DailyTextKept, RightDay, NoRepeatedText, WindowMatchesDisk, ConflictVersionsMerged, NoDeadlock

## Label warnings
No label has a warning.

## Arrows
| Label | From | To | TLA+ actions | Steps |
| --- | --- | --- | --- | --- |
| the clock passes midnight | This Mac: Showing today's note (day 1) | This Mac: Showing yesterday's note | Midnight | 1 |
| the midnight timer or wake switches to today | This Mac: Showing yesterday's note | This Mac: Today's note shown, file not created | Rollover | 1 |
| the person types in the daily note | This Mac: Today's note shown, file not created | This Mac: Typing, save pending | Type | 1 |
| the save timer writes the daily note | This Mac: Typing, save pending | This Mac: Today's note open | SaveFires | 2 |
| the person fixes a typo in today's line [when No file for today in iCloud] | This Mac: Today's note open | This Mac: Typing, save pending | RewriteTypo | 1 |
| the file watcher reports the change [when A conflict version of today's file is waiting] | This Mac: Today's note open | This Mac: Outside edit held back | WatcherDelivers | 1 |
| the clock passes midnight | iCloud: Day 1, no day-2 file | iCloud: No file for today in iCloud | Midnight | 1 |
| iCloud keeps an older save of this Mac as a conflict version [when Today's note open] | iCloud: No file for today in iCloud | iCloud: A conflict version of today's file is waiting | SelfConflict | 1 |
| the file watcher reports the change | iCloud: A conflict version of today's file is waiting | iCloud: No file for today in iCloud | WatcherDelivers | 1 |
