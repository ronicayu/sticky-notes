# Performance measurements

Each row is measured before and after the change that targets it, on the same
machine, with the benchmark named in the row. Benchmarks are tests that do nothing
unless `STICKY_BENCH=1` is set; numbers are from the Debug build the test suite
uses, so a release build is faster. Each figure is the median of the samples in
one run, and the "after" figures are the median of five runs.

Machine: Apple M5 Max (18 cores, 128 GB), macOS 27.0.1.

Run one with:

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

The 2 KB sample is 1,917 bytes and the 50 KB sample 50,149 bytes: 12 and 300 sections
of a heading, a paragraph with bold, italic, a link, code, a wiki link and a bare URL,
a task and a bullet.

A full restyle (load, text size, appearance) is no faster than before: it now looks for
bare URLs one paragraph at a time, which costs about what the saved regex builds gained.
