# DailyRollover

TLC reached 16,136 states, more than the chart budget of 500, so the chart draws only the bug paths: 10 states and 7 arrows.
The chart has 0 label warnings.
The chart does not draw 5 steps that stay in one chart state.
The step the clock passes midnight changes Mac A, Mac B and iCloud at the same time.
The step the midnight timer or wake switches to today changes only one of Mac A and Mac B at a time.

## DailyTextKept breaks
The shortest path has 10 steps:
0. Mac A Showing today's note (day 1), Mac B Showing today's note (day 1), iCloud Day 1, no day-2 file
1. the clock passes midnight: Mac A Showing yesterday's note, Mac B Showing yesterday's note, iCloud No file for today in iCloud
2. the person clicks into the daily note: Mac A Showing yesterday's note, Mac B Showing yesterday's note, iCloud No file for today in iCloud
3. the midnight timer or wake switches to today: Mac A Showing yesterday's note, Mac B Today's note shown, file not created, iCloud No file for today in iCloud
4. the person opens today's note from the menu: Mac A Showing yesterday's note, Mac B Today's note open, iCloud No file for today in iCloud
5. iCloud uploads the local change: Mac A Showing yesterday's note, Mac B Today's note open, iCloud One file for today in iCloud
6. iCloud downloads the newer file: Mac A Showing yesterday's note, Mac B Today's note open, iCloud One file for today in iCloud
7. iCloud evicts the file to free space: Mac A Showing yesterday's note, Mac B Today's note open, iCloud One file for today in iCloud
8. the midnight timer or wake switches to today: Mac A Waiting for today's note to download, Mac B Today's note open, iCloud One file for today in iCloud
9. the person types in the daily note: Mac A Waiting for today's note to download, Mac B Today's note open, iCloud One file for today in iCloud
10. the five-second retry reloads today's note: Mac A Waiting for today's note to download, Mac B Today's note open, iCloud One file for today in iCloud

## Rules that hold
ClockNeverCreates, DuplicateOnlyFromTwoPeople, RightDay, NoDeadlock

## Label warnings
No label has a warning.

## Arrows
| Label | From | To | TLA+ actions | Steps |
| --- | --- | --- | --- | --- |
| the clock passes midnight | Mac A: Showing today's note (day 1) | Mac A: Showing yesterday's note | Midnight | 1 |
| the midnight timer or wake switches to today [when Mac B is Today's note open and iCloud is One file for today in iCloud] | Mac A: Showing yesterday's note | Mac A: Waiting for today's note to download | Rollover | 1 |
| the clock passes midnight | Mac B: Showing today's note (day 1) | Mac B: Showing yesterday's note | Midnight | 1 |
| the midnight timer or wake switches to today | Mac B: Showing yesterday's note | Mac B: Today's note shown, file not created | Rollover | 1 |
| the person opens today's note from the menu | Mac B: Today's note shown, file not created | Mac B: Today's note open | PersonOpensToday | 1 |
| the clock passes midnight | iCloud: Day 1, no day-2 file | iCloud: No file for today in iCloud | Midnight | 1 |
| iCloud uploads the local change [when Mac B is Today's note open] | iCloud: No file for today in iCloud | iCloud: One file for today in iCloud | Upload | 1 |
