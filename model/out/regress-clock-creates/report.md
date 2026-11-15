# DailyRollover

TLC reached 8,158 states, more than the chart budget of 500, so the chart draws only the bug paths: 10 states and 7 arrows.
The chart has 0 label warnings.
The step the clock passes midnight changes Mac A, Mac B and iCloud at the same time.
The step the midnight timer or wake switches to today changes only one of Mac A and Mac B at a time.

## ClockNeverCreates breaks
The shortest path has 2 steps:
0. Mac A Showing today's note (day 1), Mac B Showing today's note (day 1), iCloud Day 1, no day-2 file
1. the clock passes midnight: Mac A Showing yesterday's note, Mac B Showing yesterday's note, iCloud No file for today in iCloud
2. the midnight timer or wake switches to today: Mac A Today's note open, Mac B Showing yesterday's note, iCloud No file for today in iCloud

## DuplicateOnlyFromTwoPeople breaks
The shortest path has 5 steps:
0. Mac A Showing today's note (day 1), Mac B Showing today's note (day 1), iCloud Day 1, no day-2 file
1. the clock passes midnight: Mac A Showing yesterday's note, Mac B Showing yesterday's note, iCloud No file for today in iCloud
2. the midnight timer or wake switches to today: Mac A Today's note open, Mac B Showing yesterday's note, iCloud No file for today in iCloud
3. the midnight timer or wake switches to today: Mac A Today's note open, Mac B Today's note open, iCloud No file for today in iCloud
4. iCloud uploads the local change: Mac A Today's note open, Mac B Today's note open, iCloud One file for today in iCloud
5. iCloud uploads the local change: Mac A Today's note open, Mac B Today's note open, iCloud Today's file plus a numbered duplicate

## Rules that hold
DailyTextKept, RightDay, NoDeadlock

## Label warnings
No label has a warning.

## Arrows
| Label | From | To | TLA+ actions | Steps |
| --- | --- | --- | --- | --- |
| the clock passes midnight | Mac A: Showing today's note (day 1) | Mac A: Showing yesterday's note | Midnight | 1 |
| the midnight timer or wake switches to today | Mac A: Showing yesterday's note | Mac A: Today's note open | Rollover | 1 |
| the clock passes midnight | Mac B: Showing today's note (day 1) | Mac B: Showing yesterday's note | Midnight | 1 |
| the midnight timer or wake switches to today [when Mac A is Today's note open] | Mac B: Showing yesterday's note | Mac B: Today's note open | Rollover | 1 |
| the clock passes midnight | iCloud: Day 1, no day-2 file | iCloud: No file for today in iCloud | Midnight | 1 |
| iCloud uploads the local change [when Mac A is Today's note open and Mac B is Today's note open] | iCloud: No file for today in iCloud | iCloud: One file for today in iCloud | Upload | 1 |
| iCloud uploads the local change | iCloud: One file for today in iCloud | iCloud: Today's file plus a numbered duplicate | Upload | 1 |
