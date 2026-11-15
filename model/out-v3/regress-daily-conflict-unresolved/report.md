# DailyDocument

TLC reached 1,506 states, more than the chart budget of 500, so the chart draws only the bug paths: 8 states and 6 arrows.
The chart has 0 label warnings.
The chart does not draw 1 steps that stay in one chart state.
The step the clock passes midnight changes This Mac and iCloud at the same time.

## ConflictVersionsMerged breaks
The shortest path has 6 steps:
0. This Mac Showing today's note (day 1), iCloud Day 1, no day-2 file
1. the clock passes midnight: This Mac Showing yesterday's note, iCloud No file for today in iCloud
2. the midnight timer or wake switches to today: This Mac Today's note shown, file not created, iCloud No file for today in iCloud
3. the person opens today's note on purpose: This Mac Today's note open, iCloud No file for today in iCloud
4. iCloud uploads this Mac's file: This Mac Today's note open, iCloud One file for today in iCloud
5. the other Mac's offline edit arrives as a conflict version: This Mac Today's note open, iCloud A conflict version of today's file is waiting
6. the file watcher reports the change: This Mac Today's note open, iCloud A conflict version of today's file is waiting

## Rules that hold
TypeOK, DailyTextKept, NoDeadlock

## Label warnings
No label has a warning.

## Arrows
| Label | From | To | TLA+ actions | Steps |
| --- | --- | --- | --- | --- |
| the clock passes midnight | This Mac: Showing today's note (day 1) | This Mac: Showing yesterday's note | Midnight | 1 |
| the midnight timer or wake switches to today | This Mac: Showing yesterday's note | This Mac: Today's note shown, file not created | Rollover | 1 |
| the person opens today's note on purpose | This Mac: Today's note shown, file not created | This Mac: Today's note open | PersonOpensToday | 1 |
| the clock passes midnight | iCloud: Day 1, no day-2 file | iCloud: No file for today in iCloud | Midnight | 1 |
| iCloud uploads this Mac's file [when Today's note open] | iCloud: No file for today in iCloud | iCloud: One file for today in iCloud | Upload | 1 |
| the other Mac's offline edit arrives as a conflict version | iCloud: One file for today in iCloud | iCloud: A conflict version of today's file is waiting | BEditsOffline | 1 |
