# DailyDocument

TLC reached 70,281 states, more than the chart budget of 500, so the chart draws only the bug paths: 7 states and 5 arrows.
The chart has 0 label warnings.
The chart does not draw 5 steps that stay in one chart state.
The step the clock passes midnight changes This Mac and iCloud at the same time.

## DailyTextKept breaks
The shortest path has 9 steps:
0. This Mac Showing today's note (day 1), iCloud Day 1, no day-2 file
1. the person clicks into the daily note: This Mac Showing today's note (day 1), iCloud Day 1, no day-2 file
2. the clock passes midnight: This Mac Showing yesterday's note, iCloud No file for today in iCloud
3. the other Mac creates today's file offline: This Mac Showing yesterday's note, iCloud The other Mac created today's file offline
4. iCloud uploads the other Mac's new file: This Mac Showing yesterday's note, iCloud One file for today in iCloud
5. iCloud downloads the newer file to this Mac: This Mac Showing yesterday's note, iCloud One file for today in iCloud
6. iCloud turns the synced file into a placeholder: This Mac Showing yesterday's note, iCloud One file for today in iCloud
7. the midnight timer or wake switches to today: This Mac Waiting for today's note to download, iCloud One file for today in iCloud
8. the person types in the daily note: This Mac Waiting for today's note to download, iCloud One file for today in iCloud
9. the five-second retry looks for the download again: This Mac Waiting for today's note to download, iCloud One file for today in iCloud

## Rules that hold
TypeOK, ClockNeverCreates, DuplicateOnlyFromTwoPeople, RightDay, NoSpuriousConflictBlock, NoRepeatedText, WindowMatchesDisk, ConflictVersionsMerged, NoDeadlock

## Label warnings
No label has a warning.

## Arrows
| Label | From | To | TLA+ actions | Steps |
| --- | --- | --- | --- | --- |
| the clock passes midnight | This Mac: Showing today's note (day 1) | This Mac: Showing yesterday's note | Midnight | 1 |
| the midnight timer or wake switches to today [when One file for today in iCloud] | This Mac: Showing yesterday's note | This Mac: Waiting for today's note to download | Rollover | 1 |
| the clock passes midnight | iCloud: Day 1, no day-2 file | iCloud: No file for today in iCloud | Midnight | 1 |
| the other Mac creates today's file offline | iCloud: No file for today in iCloud | iCloud: The other Mac created today's file offline | BCreatesOffline | 1 |
| iCloud uploads the other Mac's new file | iCloud: The other Mac created today's file offline | iCloud: One file for today in iCloud | BUploads | 1 |
