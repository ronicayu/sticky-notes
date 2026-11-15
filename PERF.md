# Performance measurements

Each row is measured before and after the change that targets it, on the same
machine, with the benchmark named in the row. Benchmarks are tests that do nothing
unless `STICKY_BENCH=1` is set; numbers are from the Debug build the test suite
uses, so a release build is faster. Each figure is the median of the samples in
one run; the restyle "after" figures are then the median of five runs and the idle
ones of three.

Machine: Apple M5 Max (18 cores, 128 GB), macOS 27.0.1.

Run one with (any benchmark class works the same way):

```
source /tmp/ds-env.sh && STICKY_BENCH=1 /Applications/Xcode.app/Contents/Developer/usr/bin/xctest \
  -XCTest StickyNotesTests.RestyleBenchTests .build/out/Products/Debug/StickyNotesTests.xctest
```

| What | Benchmark | Before | After | Change |
|------|-----------|--------|-------|--------|
| One typed character in a 2 KB note, through the editor (text change, restyle, marker visibility, layout) | `RestyleBenchTests` | 17.9 ms | 2.0 ms | item 3.3 |
| One typed character in a 50 KB note, through the editor | `RestyleBenchTests` | 477 ms | 3.8 ms | item 3.3 |
| Styler alone, 2 KB: full pass, and the one-paragraph pass an edit now takes | `RestyleBenchTests` | 3.2 ms (full only) | 3.8 ms full, 0.6 ms one paragraph | item 3.3 |
| Styler alone, 50 KB: full pass, and the one-paragraph pass an edit now takes | `RestyleBenchTests` | 96 ms (full only) | 104 ms full, 2.0 ms one paragraph | item 3.3 |
| Disk reads per save (one pause in typing), 40 notes open, notes panel created and then closed | `IdleCostBenchTests` | 10.7 | 5.3 | item 3.4 |
| CPU per save, same set-up | `IdleCostBenchTests` | 14.8 ms | 3.6 ms | item 3.4 |
| Notes panel list rebuilds per save, same set-up | `IdleCostBenchTests` | 1.1 | 0 | item 3.4 |
| Main-thread busy time per save, from the save to the end of what the file watcher's report sets off, 200 notes, 40 open, 20 files dataless | `DatalessBenchTests` | 663 ms | 12.9 ms | dataless reads, own FSEvents echo |
| Main-thread CPU time, same | `DatalessBenchTests` | 292 ms | 10.4 ms | same |
| File reads per save, same | `DatalessBenchTests` | 401 | 1.0 | same |
| Of those, reads of dataless files | `DatalessBenchTests` | 40 | 0 | same |

The same 40-note set-up with no panel created costs 5.3 disk reads and 3.4 ms CPU per
save before and after the change, so the panel's own share was 5.3 reads and 11 ms and is
now nil. The 5.3 reads are the store's own, for the save and the windows. Each run is
60 saves after a warm-up of 60; the benchmark saves one note
and then runs the main queue so the panel's deferred reload would run. The quick switcher
has no store observer, so a hidden switcher already cost nothing; it is covered by a test,
not a row.

The 2 KB sample is 1,917 bytes and the 50 KB sample 50,149 bytes: 12 and 300 sections
of a heading, a paragraph with bold, italic, a link, code, a wiki link and a bare URL,
a task and a bullet.

A full restyle (load, text size, appearance) is no faster than before: it now looks for
bare URLs one paragraph at a time, which costs about what the saved regex builds gained.

The dataless rows are the median of three runs. A test machine has no dataless files, so
the benchmark names 20 of the 200 note files (10 with an open window, 10 without) as
dataless through the store's `isDataless` seam, and every read of one that gets
through costs 5 ms on the main thread, a stand-in: a real read waits for a download, which
takes anything from tens of milliseconds to minutes. "Before" is the tree before the change
with only that seam and its stall added, so the reads go ahead and stall; "after" is the
tree with the change, where the seam makes the store skip the read. Of the 663 ms, 200 ms is
the stall (40 dataless reads of 5 ms); the rest is the reads and parses of the other 360
files and the redraws they set off. With a real download in place of 5 ms, each of the 40
reads would be a freeze of its own. The "before" figures were taken on `f4caf9e` with a
temporary seam added (the same `isDataless` and `willReadFile` the benchmark uses, the
stall in the hook), so they cannot be reproduced from the repository as it now stands. The save writes through the real file system, so the watcher reports
the write (before) or, flagged as our own, does not (after), and the desk and the 40 windows
react as in the app: before, every window reads its file and the desk lists and reads all
200; after, the one read is the compare-and-swap read inside the save. The benchmark
measures the time the main run loop spends running work, plus the save call itself.
