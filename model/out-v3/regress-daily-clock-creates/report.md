# DailyDocument

TLC reached 3,089 states, more than the chart budget of 500, so the chart draws only the bug paths: 8 states and 6 arrows.
The chart has 0 label warnings.
The step the clock passes midnight changes This Mac and iCloud at the same time.

## ClockNeverCreates breaks
The shortest path has 2 steps:
0. This Mac Showing today's note (day 1), iCloud Day 1, no day-2 file
1. the clock passes midnight: This Mac Showing yesterday's note, iCloud No file for today in iCloud
2. the midnight timer or wake switches to today: This Mac Today's note open, iCloud No file for today in iCloud

## DuplicateOnlyFromTwoPeople breaks
The shortest path has 5 steps:
0. This Mac Showing today's note (day 1), iCloud Day 1, no day-2 file
1. the clock passes midnight: This Mac Showing yesterday's note, iCloud No file for today in iCloud
2. the midnight timer or wake switches to today: This Mac Today's note open, iCloud No file for today in iCloud
3. iCloud uploads this Mac's file: This Mac Today's note open, iCloud One file for today in iCloud
4. the other Mac creates today's file offline: This Mac Today's note open, iCloud The other Mac created today's file offline
5. iCloud uploads the other Mac's new file: This Mac Today's note open, iCloud Today's file plus a numbered duplicate

## Rules that hold
TypeOK, DailyTextKept, RightDay, NoSpuriousConflictBlock, NoRepeatedText, WindowMatchesDisk, ConflictVersionsMerged, NoDeadlock

## Label warnings
No label has a warning.

## Arrows
| Label | From | To | TLA+ actions | Steps |
| --- | --- | --- | --- | --- |
| the clock passes midnight | This Mac: Showing today's note (day 1) | This Mac: Showing yesterday's note | Midnight | 1 |
| the midnight timer or wake switches to today | This Mac: Showing yesterday's note | This Mac: Today's note open | Rollover | 1 |
| the clock passes midnight | iCloud: Day 1, no day-2 file | iCloud: No file for today in iCloud | Midnight | 1 |
| iCloud uploads this Mac's file [when Today's note open] | iCloud: No file for today in iCloud | iCloud: One file for today in iCloud | Upload | 1 |
| the other Mac creates today's file offline | iCloud: One file for today in iCloud | iCloud: The other Mac created today's file offline | BCreatesOffline | 1 |
| iCloud uploads the other Mac's new file | iCloud: The other Mac created today's file offline | iCloud: Today's file plus a numbered duplicate | BUploads | 1 |
