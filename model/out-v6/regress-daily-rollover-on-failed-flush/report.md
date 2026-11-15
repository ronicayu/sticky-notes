# DailyDocument

TLC reached 23,120 states, more than the chart budget of 500, so the chart draws only the bug paths: 6 states and 4 arrows.
The chart has 0 label warnings.
The chart does not draw 2 steps that stay in one chart state.
The step the clock passes midnight changes This Mac and iCloud at the same time.

## DailyTextKept breaks
The shortest path has 5 steps:
0. This Mac Showing today's note (day 1), iCloud Day 1, no day-2 file
1. the person clicks into the daily note: This Mac Showing today's note (day 1), iCloud Day 1, no day-2 file
2. the person types in the daily note: This Mac Typing, save pending, iCloud Day 1, no day-2 file
3. the clock passes midnight: This Mac Showing yesterday's note, save pending, iCloud No file for today in iCloud
4. this Mac's disk stops accepting writes: This Mac Showing yesterday's note, save pending, iCloud No file for today in iCloud
5. the midnight timer or wake switches to today: This Mac Today's note shown, file not created, iCloud No file for today in iCloud

## Rules that hold
TypeOK, ClockNeverCreates, DuplicateOnlyFromTwoPeople, RightDay, NoSpuriousConflictBlock, NoRepeatedText, WindowMatchesDisk, ConflictVersionsMerged, NoDeadlock

## Label warnings
No label has a warning.

## Arrows
| Label | From | To | TLA+ actions | Steps |
| --- | --- | --- | --- | --- |
| the person types in the daily note | This Mac: Showing today's note (day 1) | This Mac: Typing, save pending | Type | 1 |
| the clock passes midnight | This Mac: Typing, save pending | This Mac: Showing yesterday's note, save pending | Midnight | 1 |
| the midnight timer or wake switches to today | This Mac: Showing yesterday's note, save pending | This Mac: Today's note shown, file not created | Rollover | 1 |
| the clock passes midnight [when Typing, save pending] | iCloud: Day 1, no day-2 file | iCloud: No file for today in iCloud | Midnight | 1 |
