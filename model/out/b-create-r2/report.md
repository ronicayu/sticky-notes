# DailyRollover

TLC reached 72,203 states, more than the chart budget of 500, so the chart draws only the bug paths: 13 states and 10 arrows.
The chart has 0 label warnings.
The chart does not draw 7 steps that stay in one chart state.
The step the clock passes midnight changes Mac A, Mac B and iCloud at the same time.
The step the midnight timer or wake switches to today changes only one of Mac A and Mac B at a time.
The step the person types in the daily note changes only one of Mac A and Mac B at a time.
The step the save timer writes the daily note changes only one of Mac A and Mac B at a time.

## DailyTextKept breaks
The shortest path has 15 steps:
0. Mac A Showing today's note (day 1), Mac B Showing today's note (day 1), iCloud Day 1, no day-2 file
1. the clock passes midnight: Mac A Showing yesterday's note, Mac B Showing yesterday's note, iCloud No file for today in iCloud
2. the person clicks into the daily note: Mac A Showing yesterday's note, Mac B Showing yesterday's note, iCloud No file for today in iCloud
3. the midnight timer or wake switches to today: Mac A Today's note shown, file not created, Mac B Showing yesterday's note, iCloud No file for today in iCloud
4. the person types in the daily note: Mac A Typing, save pending, Mac B Showing yesterday's note, iCloud No file for today in iCloud
5. the person grabs the daily note's title bar: Mac A Typing, save pending, Mac B Showing yesterday's note, iCloud No file for today in iCloud
6. the save timer writes the daily note: Mac A Today's note open, Mac B Showing yesterday's note, iCloud No file for today in iCloud
7. the person clicks into the daily note: Mac A Today's note open, Mac B Showing yesterday's note, iCloud No file for today in iCloud
8. the midnight timer or wake switches to today: Mac A Today's note open, Mac B Today's note shown, file not created, iCloud No file for today in iCloud
9. the person types in the daily note: Mac A Today's note open, Mac B Typing, save pending, iCloud No file for today in iCloud
10. iCloud uploads the local change: Mac A Today's note open, Mac B Typing, save pending, iCloud One file for today in iCloud
11. iCloud downloads the newer file: Mac A Today's note open, Mac B Typing, save pending, iCloud One file for today in iCloud
12. the save timer writes the daily note: Mac A Today's note open, Mac B Today's note open, iCloud One file for today in iCloud
13. iCloud uploads the local change: Mac A Today's note open, Mac B Today's note open, iCloud One file for today in iCloud
14. iCloud downloads the newer file: Mac A Today's note open, Mac B Today's note open, iCloud One file for today in iCloud
15. the file watcher reports the change: Mac A Today's note open, Mac B Today's note open, iCloud One file for today in iCloud

## Rules that hold
ClockNeverCreates, DuplicateOnlyFromTwoPeople, RightDay, NoDeadlock

## Label warnings
No label has a warning.

## Arrows
| Label | From | To | TLA+ actions | Steps |
| --- | --- | --- | --- | --- |
| the clock passes midnight | Mac A: Showing today's note (day 1) | Mac A: Showing yesterday's note | Midnight | 1 |
| the midnight timer or wake switches to today | Mac A: Showing yesterday's note | Mac A: Today's note shown, file not created | Rollover | 1 |
| the person types in the daily note | Mac A: Today's note shown, file not created | Mac A: Typing, save pending | Type | 1 |
| the save timer writes the daily note | Mac A: Typing, save pending | Mac A: Today's note open | SaveFires | 1 |
| the clock passes midnight | Mac B: Showing today's note (day 1) | Mac B: Showing yesterday's note | Midnight | 1 |
| the midnight timer or wake switches to today [when Mac A is Today's note open] | Mac B: Showing yesterday's note | Mac B: Today's note shown, file not created | Rollover | 1 |
| the person types in the daily note | Mac B: Today's note shown, file not created | Mac B: Typing, save pending | Type | 1 |
| the save timer writes the daily note [when iCloud is One file for today in iCloud] | Mac B: Typing, save pending | Mac B: Today's note open | SaveFires | 1 |
| the clock passes midnight | iCloud: Day 1, no day-2 file | iCloud: No file for today in iCloud | Midnight | 1 |
| iCloud uploads the local change [when Mac A is Today's note open and Mac B is Typing, save pending] | iCloud: No file for today in iCloud | iCloud: One file for today in iCloud | Upload | 1 |
