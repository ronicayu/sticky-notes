---------------------------- MODULE DailyDocument ----------------------------
\* Model (b), v2: today's daily note across one midnight, on this Mac (A) with a
\* window, and a second Mac (B) that only acts through iCloud. The owner uses the
\* two Macs in turn and never types on both at once, so B has no window: it
\* writes the day's file after a sync, edits an older copy while offline (an
\* iCloud conflict version), or creates the day's file offline (a numbered
\* duplicate). This Mac's iCloud may also keep an older save of its own.
\* Code modelled: commit c16cef1 (DailyDocument.swift, DailyFile, NoteDocument
\* shared rules). NOTES.md maps every action to file:line.
\*
\* Switch convention as in NoteDocument.tla: ALLOW_OLD_* = FALSE is the code as it
\* is; TRUE brings back one bug that a commit since the first model run fixed.
\*
\* Text: sequences of line tokens (LineMerge.tla). "T" the rendered template,
\* "a1" / "a2" typed on this Mac on day 1 / day 2, "b2" written on the other
\* Mac on day 2, "D" a conflict divider.

EXTENDS LineMerge, FiniteSets, Naturals, Sequences

CONSTANTS
  TEMPLATE,                        \* a daily template is configured
  \* --- environment (TRUE = can happen) ---
  ALLOW_EVICTION,                  \* iCloud turns a synced file into a dataless placeholder
  ALLOW_A_TYPES_DAY1,              \* the person types on this Mac just before midnight
  ALLOW_B_EDITS_ONLINE,            \* the other Mac appends to the synced file
  ALLOW_B_EDITS_OFFLINE,           \* the other Mac edits an older copy: an iCloud conflict version
  ALLOW_B_CREATES_OFFLINE,         \* the other Mac creates the day's file before it sees this Mac's
  ALLOW_SELF_CONFLICT,             \* iCloud keeps an older save of this Mac as a conflict version
  EXCUSE_STALE_BLOCK,              \* design choice: a block of two own texts after an earlier own file was kept next to our newest is not spurious (TRUE); FALSE shows it
  ALLOW_WRITE_FAILURE,             \* writes on this Mac fail for a while
  \* --- findings N2 and N6 of the re-run model, fixed after c16cef1 (TRUE = bring the c16cef1 behaviour back) ---
  ALLOW_OLD_BLANK_WINNER_BLOCK,    \* N2: a blank file is not replaced by a conflict version that has text
  ALLOW_OLD_NO_MERGE_RETRY,        \* N6: a merge that could not be written is retried only by the next file event
  \* --- bugs fixed since the first model run (TRUE = bring the old behaviour back) ---
  ALLOW_OLD_CLOCK_CREATES,         \* cbbec66: the rollover wrote the template, creating the file
  ALLOW_OLD_STUB_AS_MISSING,       \* 0.5: an unreadable file was treated as missing
  ALLOW_OLD_APPLY_OVER_UNSAVED,    \* F7: reload applied the file over an armed save (R4)
  ALLOW_OLD_BLIND_WRITE,           \* F8: a save did not check the file first (R5)
  ALLOW_OLD_CONFLICT_UNRESOLVED,   \* F9: conflict versions of the daily file were never merged
  ALLOW_OLD_PLACEHOLDER_EDITABLE,  \* F10: the "waiting" buffer took typing (R6, R7)
  ALLOW_OLD_ROLLOVER_ON_FAILED_FLUSH, \* R15: midnight replaced a buffer whose save failed
  ALLOW_OLD_NO_LINEAGE,            \* an older own save was merged as a conflict
  ALLOW_OLD_SWEEP_NO_FLUSH,        \* conflict versions merged before the typing was written
  ALLOW_OLD_HEAL_NO_FLUSH,         \* a numbered duplicate healed before the typing was written
  ALLOW_OLD_UNBASED_MERGE          \* merge without the base the document last saw

Days   == {1, 2}
Tmpl   == IF TEMPLATE THEN <<"T">> ELSE <<>>
Real   == {"T", "a1", "a2", "r2", "b2"}
DayOf(tok) == IF tok = "a1" THEN 1 ELSE 2

NoFile == [st |-> "none", c |-> <<>>, origin |-> "new", dirty |-> FALSE]
Synced(c) == [st |-> "file", c |-> c, origin |-> "fresh", dirty |-> FALSE]

VARIABLE s
vars == <<s>>

Init == s = [
  day |-> 1, shown |-> 1, unavail |-> FALSE, diskFull |-> FALSE,
  buf |-> Tmpl, base |-> Tmpl, hasPend |-> FALSE, pend |-> <<>>,
  armed |-> FALSE, unsaved |-> FALSE, focus |-> "away", fp |-> "ok", unseen |-> FALSE,
  lf |-> [d \in Days |-> IF d = 1 THEN Synced(Tmpl) ELSE NoFile],
  lin |-> [d \in Days |-> {}], linM |-> [d \in Days |-> {}], linNew |-> [d \in Days |-> <<>>],
  hasPrev |-> FALSE, prev |-> <<>>, diskOwn |-> FALSE,
  srvMain |-> [d \in Days |-> d = 1], srvC |-> [d \in Days |-> IF d = 1 THEN Tmpl ELSE <<>>],
  dup |-> FALSE, dupC |-> <<>>, dupSeen |-> FALSE, dupCopy |-> <<>>,
  conf |-> <<>>, hasConf |-> FALSE, confKind |-> "none",
  bPend |-> <<>>, hasBPend |-> FALSE,
  typed |-> {}, used |-> {}, clockCreated |-> FALSE, aCreated |-> FALSE, bCreated |-> FALSE,
  spurious |-> FALSE, brk |-> FALSE ]

-----------------------------------------------------------------------------
\* Helpers

\* A read of the file changes nothing now (c16cef1: it ended the write lineage unless the file
\* held our newest write). The lineage ends only when the document takes over text that
\* lacks lines it showed (`Adopted`).
Rd(t, d) == t

\* WriteLineage.adopted: the document took `new` as the text in place of `old`; if lines
\* of `old` are missing from it, the person did not take them out and the lineage ends.
Adopted(t, d, old, new) ==
  IF t.lin[d] # {} /\ ~Covered(old, new) THEN [t EXCEPT !.lin[d] = {}, !.linM[d] = {}, !.brk = TRUE] ELSE t

\* The file is an earlier write of ours that was put back, not our newest: the sweep
\* judges our newest text in its place (DailyFile.resolveConflicts, `judged`).
\* Bodies a window saved; a body only the store wrote as a merge (`linM`) vouches for nothing.
Own(t, d) == t.lin[d] \ t.linM[d]

StaleFile(t, d) == t.lin[d] # {} /\ t.lf[d].c \in Own(t, d) /\ t.lf[d].c # t.linNew[d]

\* ConflictResolver.versionsToMerge: an own conflict version is dropped when it is an
\* earlier write than the newest and the newest write's text is in the file.
DropsOwn(t, d, c) ==
  /\ ~ALLOW_OLD_NO_LINEAGE /\ t.lin[d] # {} /\ c \in Own(t, d)
  /\ c # t.linNew[d] /\ (StaleFile(t, d) \/ Covered(t.linNew[d], t.lf[d].c))

Out(t, ok) == [st |-> t, ok |-> ok]

\* This Mac writes body b to its local file for day d (DailyFile.write / replaceFile).
WriteLocal(t, d, b) ==
  LET f == t.lf[d]
  IN [t EXCEPT !.lf[d] = [st |-> "file", c |-> b,
                          origin |-> IF f.st = "none" THEN "new" ELSE f.origin, dirty |-> TRUE],
               !.lin[d] = t.lin[d] \cup {b}, !.linM[d] = t.linM[d] \ {b}, !.linNew[d] = b,
               !.hasPrev = t.hasPrev \/ t.diskOwn,
               !.prev = IF t.diskOwn /\ d = 2 THEN t.lf[d].c ELSE t.prev, !.diskOwn = TRUE,
               !.unseen = TRUE]

\* The same for a write the store makes from other versions (heal, conflict merge).
WriteMerged(t, d, b) ==
  LET w == WriteLocal(t, d, b) IN [w EXCEPT !.linM[d] = w.linM[d] \cup ({b} \ t.lin[d])]

\* The document merges an outside version `ext` into the buffer (three-way against base).
MergeIn(t, ext, known) ==
  LET r == IF ALLOW_OLD_UNBASED_MERGE THEN MergeVersions(t.buf, ext, FALSE, FALSE)
           ELSE IF t.buf # t.base /\ ext \in Own(t, t.shown) /\ ext # t.linNew[t.shown]
             THEN [c |-> t.buf, blk |-> FALSE, sp |-> FALSE]   \* N1: an older copy of our own text adds nothing
           ELSE ThreeWay(t.base, t.buf, ext)
  IN [Adopted(t, t.shown, t.buf, r.c) EXCEPT !.buf = r.c, !.base = ext, !.hasPend = FALSE, !.pend = <<>>,
               !.fp = IF known THEN "ok" ELSE t.fp, !.spurious = t.spurious \/ (r.sp /\ ~t.brk)]

ReadableFile(t) == t.lf[t.shown].st = "file"

MergePend(t) ==
  IF ~t.hasPend THEN t
  ELSE IF ReadableFile(t) THEN MergeIn(Rd(t, t.shown), t.lf[t.shown].c, TRUE)
  ELSE MergeIn(t, t.pend, FALSE)

\* NoteDocument.persist for the daily file (DailyFile.save).
Persist(t) ==
  LET d == t.shown
      f == t.lf[d]
      markWrite(u) == [WriteLocal(u, d, u.buf) EXCEPT !.base = u.buf, !.unsaved = FALSE, !.fp = "ok",
                       !.aCreated = t.aCreated \/ (d = 2 /\ f.st = "none")]
  IN IF f.st = "stub" \/ t.diskFull THEN Out([t EXCEPT !.armed = TRUE], FALSE)
     ELSE IF f.st = "file" /\ t.fp # "ok" /\ ~ALLOW_OLD_BLIND_WRITE
       THEN Out(markWrite(MergeIn(Rd(t, d), f.c, TRUE)), TRUE)    \* conflict: merge, save again
     ELSE Out(markWrite(t), TRUE)

\* DailyDocument.flush: writes a debounced edit now; true when there is nothing to write.
Flush(t) ==
  IF t.unavail \/ ~t.armed THEN Out(t, TRUE)
  ELSE Persist(MergePend([t EXCEPT !.armed = FALSE]))

\* DailyNote.healDuplicates: the numbered duplicate is merged into the file and trashed.
Heal(t) ==
  IF ~t.dupSeen \/ t.shown # 2 \/ t.lf[2].st # "file" \/ t.diskFull THEN t
  ELSE LET merged == MergeBodies(t.lf[2].c, t.dupCopy)
           t1 == IF merged.c # t.lf[2].c THEN WriteMerged(Rd(t, 2), 2, merged.c) ELSE t
       IN [t1 EXCEPT !.dupSeen = FALSE, !.dupCopy = <<>>, !.dup = FALSE, !.dupC = <<>>,
                     !.spurious = t.spurious \/ merged.sp]

\* ExternalChange (NoteDocument.externalChange) on the daily file.
ExternalChange(t0) ==
  LET t == Rd(t0, t0.shown)
      disk == t.lf[t.shown].c
      defer == IF ALLOW_OLD_APPLY_OVER_UNSAVED THEN t.focus = "typing"
               ELSE (t.armed \/ t.buf # t.base) \/ t.focus = "typing"
  IN IF disk = t.base THEN [t EXCEPT !.fp = "ok"]
     ELSE IF disk = t.buf THEN [t EXCEPT !.base = disk, !.fp = "ok"]
     ELSE IF defer THEN [t EXCEPT !.hasPend = TRUE, !.pend = disk]
     ELSE [Adopted(t, t.shown, t.buf, disk) EXCEPT !.buf = disk, !.base = disk, !.fp = "ok"]

Adopt(t, body, fp, unavail) ==
  [Adopted(t, t.shown, t.linNew[t.shown], body) EXCEPT !.buf = body, !.base = body, !.fp = fp, !.unavail = unavail, !.hasPend = FALSE,
            !.pend = <<>>, !.armed = FALSE, !.unsaved = FALSE]

\* snapshot(); if the file cannot be read nothing changes; waiting for a download ends.
Read(t) ==
  IF ~ReadableFile(t) THEN t
  ELSE IF t.unavail THEN Adopt(Rd(t, t.shown), t.lf[t.shown].c, "ok", FALSE)
  ELSE ExternalChange(t)

\* ResolveConf with the winner chosen: `w` = the conflict version has the newest save date.
ResolveConfWith(t, w) ==
  IF ALLOW_OLD_CONFLICT_UNRESOLVED \/ ~t.hasConf \/ t.shown # 2 \/ t.lf[2].st # "file"
    THEN t
  ELSE IF t.diskFull          \* the merge cannot be written: the versions stay
    THEN IF ALLOW_OLD_NO_MERGE_RETRY THEN t ELSE [t EXCEPT !.unseen = TRUE]
  ELSE LET u == Rd(t, 2)
           disk == u.lf[2].c
           \* An earlier write of ours put back: our newest text stands in for it when it covers the
           \* file; if not, the file may be a restore made on purpose, so both texts are merged.
           stands == StaleFile(u, 2) /\ Covered(disk, u.linNew[2])
           added == StaleFile(u, 2) /\ ~stands
           m == MergeVersions(disk, u.linNew[2], FALSE, TRUE)
           cur == IF stands THEN u.linNew[2] ELSE IF added THEN m.c ELSE disk
           dropOwn == DropsOwn(u, 2, u.conf)
           cleared == [u EXCEPT !.hasConf = FALSE, !.conf = <<>>, !.confKind = "none"]
           win == IF w /\ u.confKind = "other" THEN u.conf ELSE cur
           lose == IF w /\ u.confKind = "other" THEN cur ELSE u.conf
           r == IF dropOwn \/ u.conf = cur THEN [c |-> cur, blk |-> FALSE, sp |-> FALSE]
                ELSE MergeVersions(win, lose, FALSE, ~ALLOW_OLD_BLANK_WINNER_BLOCK)
       IN IF r.c = disk THEN cleared
          ELSE [WriteMerged(cleared, 2, r.c) EXCEPT !.spurious = cleared.spurious \/ (r.sp /\ ~cleared.brk /\ u.conf \notin u.linM[2] /\ disk \notin u.linM[2])
                                                         \/ (added /\ m.sp /\ ~EXCUSE_STALE_BLOCK)]


\* DailyDocument.load for the day now: heal, merge conflict versions, read, else seed.
\* (The caller wrote any unsaved text first.)
Load(t, w) ==
  LET t0 == [t EXCEPT !.shown = t.day]
      t1 == Heal(t0)
      t2 == ResolveConfWith(t1, w)
      f == t2.lf[t2.day]
  IN IF f.st = "file" THEN Adopt(Rd(t2, t2.day), f.c, "ok", FALSE)
     ELSE IF f.st = "stub" /\ ~ALLOW_OLD_STUB_AS_MISSING THEN Adopt(t2, <<>>, "none", TRUE)
     ELSE IF ALLOW_OLD_CLOCK_CREATES \/ (f.st = "stub" /\ ALLOW_OLD_STUB_AS_MISSING)
       THEN \* old code: write the template at once, over a stub too
            LET u == [t2 EXCEPT !.lf[t2.day] = [st |-> "file", c |-> Tmpl,
                                    origin |-> IF f.st = "stub" THEN "fresh" ELSE "new", dirty |-> TRUE],
                                !.unseen = TRUE]
            IN Adopt([u EXCEPT !.clockCreated = t2.clockCreated \/ f.st = "none"], Tmpl, "ok", FALSE)
     ELSE Adopt(t2, Tmpl, "none", FALSE)      \* seedBuffer: the template, no file

-----------------------------------------------------------------------------
\* The person on this Mac

Token(d) == IF d = 1 THEN "a1" ELSE "a2"

Type ==
  /\ s.focus = "typing"
  /\ s.shown = 2 \/ ALLOW_A_TYPES_DAY1
  /\ ~s.unavail \/ ALLOW_OLD_PLACEHOLDER_EDITABLE
  /\ Token(s.shown) \notin s.used
  /\ s' = [s EXCEPT !.buf = Append(s.buf, Token(s.shown)),
                    !.typed = s.typed \cup {Token(s.shown)}, !.used = s.used \cup {Token(s.shown)},
                    !.armed = TRUE, !.unsaved = TRUE]

\* The person fixes a typo in the line typed today (a backspace, not an append).
RewriteTypo ==
  /\ s.focus = "typing" /\ s.shown = 2 /\ ~s.unavail
  /\ "a2" \in Toks(s.buf) /\ "r2" \notin s.used
  /\ s' = [s EXCEPT !.buf = [i \in 1..Len(s.buf) |-> IF s.buf[i] = "a2" THEN "r2" ELSE s.buf[i]],
                    !.typed = (s.typed \ {"a2"}) \cup {"r2"}, !.used = s.used \cup {"r2"},
                    !.armed = TRUE, !.unsaved = TRUE]

ClickIntoText == s.focus # "typing" /\ s' = [s EXCEPT !.focus = "typing"]
GrabTitleBar  == s.focus = "typing" /\ s' = [s EXCEPT !.focus = "titlebar"]

\* windowDidResignKey: DailyDocument.blur folds in a held-back outside edit.
SwitchAway ==
  /\ s.focus # "away"
  /\ LET t == [s EXCEPT !.focus = "away"]
     IN s' = IF t.hasPend /\ ~t.unavail THEN Persist(MergePend(t)).st ELSE t

\* The 0.4 s debounce fires.
SaveFires ==
  /\ s.armed
  /\ LET t == [s EXCEPT !.armed = FALSE]
     IN s' = IF t.unavail THEN t              \* the old "waiting" buffer: nothing is written
             ELSE Persist(MergePend(t)).st

\* show(userInitiated: true) -> createTodaysFileIfMissing: requestSave + flush.
PersonOpensToday ==
  /\ s.shown = s.day /\ ~s.unavail /\ s.lf[s.day].st = "none" /\ ~s.armed
  /\ s' = Persist([s EXCEPT !.armed = FALSE]).st

-----------------------------------------------------------------------------
\* Clock and watcher

Midnight == s.day = 1 /\ s' = [s EXCEPT !.day = 2]

\* handleMidnight / wake: the old day is saved first; if that fails the new day is not opened.
Rollover ==
  /\ s.shown < s.day
  /\ LET f == Flush(s)
     IN IF f.ok \/ ALLOW_OLD_ROLLOVER_ON_FAILED_FLUSH
          THEN \E w \in BOOLEAN : s' = Load(f.st, w)
        ELSE s' = f.st

\* The 5 s retry while waiting for a download.
UnavailableRetry == s.unavail /\ \E w \in BOOLEAN : s' = Load(s, w)

\* DailyDocument.storeDidChange.
WatcherDelivers ==
  /\ s.unseen
  /\ LET t0 == [s EXCEPT !.unseen = FALSE]
         \* the typing is written before a duplicate is folded in (result ignored)
         t1 == IF t0.dupSeen /\ ~ALLOW_OLD_HEAL_NO_FLUSH THEN Flush(t0).st ELSE t0
         t2 == Heal(t1)
     IN \/ \* conflict versions: the typing is written first, and the sweep waits if that fails
           /\ t2.hasConf /\ t2.shown = 2 /\ ~ALLOW_OLD_CONFLICT_UNRESOLVED
           /\ LET f == IF ALLOW_OLD_SWEEP_NO_FLUSH THEN Out(t2, TRUE) ELSE Flush(t2)
              IN IF f.ok
                   THEN \E w \in BOOLEAN : s' = Read(ResolveConfWith(f.st, w))
                   ELSE s' = Read(f.st)
        \/ /\ ~(t2.hasConf /\ t2.shown = 2 /\ ~ALLOW_OLD_CONFLICT_UNRESOLVED)
           /\ s' = Read(t2)

-----------------------------------------------------------------------------
\* iCloud and the other Mac

\* iCloud replaced the bytes of this Mac's file for day d: a stored fingerprint of it is behind.
StaleFp(t, d) == IF t.shown = d /\ t.fp = "ok" THEN "stale" ELSE t.fp

SetSrv(t, d, c) == [t EXCEPT !.srvMain[d] = TRUE, !.srvC[d] = c]

\* This Mac uploads its dirty local file for day d.
Upload(d) ==
  /\ s.lf[d].st = "file" /\ s.lf[d].dirty
  /\ LET f == s.lf[d]
         stale(t) == IF t.lf[d].origin = "fresh" THEN t ELSE t
     IN IF ~s.srvMain[d]
          THEN s' = SetSrv([s EXCEPT !.lf[d] = Synced(f.c)], d, f.c)
        ELSE IF f.origin = "new"
          THEN \* two independent creates: iCloud keeps both; ours becomes "<date> 2"
               /\ d = 2 /\ ~s.dup
               /\ s' = [s EXCEPT !.dup = TRUE, !.dupC = f.c, !.dupSeen = TRUE, !.dupCopy = f.c,
                                 !.lf[d] = Synced(s.srvC[d]), !.unseen = TRUE, !.fp = StaleFp(s, d), !.diskOwn = FALSE]
        ELSE IF f.origin = "fresh"
          THEN s' = SetSrv([s EXCEPT !.lf[d] = Synced(f.c)], d, f.c)
        ELSE \* edited a stale copy: iCloud keeps one version as the file and one as a conflict version
             /\ d = 2 /\ ~s.hasConf
             /\ \E oursWins \in BOOLEAN :
                  IF oursWins
                    THEN s' = SetSrv([s EXCEPT !.lf[d] = Synced(f.c), !.hasConf = TRUE,
                                               !.conf = s.srvC[d], !.confKind = "other", !.unseen = TRUE], d, f.c)
                    ELSE s' = [s EXCEPT !.lf[d] = Synced(s.srvC[d]), !.hasConf = TRUE, !.conf = f.c,
                                        !.confKind = "own", !.unseen = TRUE, !.fp = StaleFp(s, d), !.diskOwn = FALSE]

\* This Mac downloads the server's version (none yet, a stub, or a stale clean copy).
Download(d) ==
  /\ s.srvMain[d]
  /\ LET f == s.lf[d] IN
       /\ ~f.dirty
       /\ (f.st \in {"none", "stub"} \/ f.origin = "stale")
       /\ s' = [s EXCEPT !.lf[d] = Synced(s.srvC[d]), !.unseen = TRUE, !.fp = StaleFp(s, d), !.diskOwn = FALSE]

Evict ==
  /\ ALLOW_EVICTION
  /\ s.lf[2].st = "file" /\ ~s.lf[2].dirty /\ s.lf[2].origin = "fresh"
  /\ s' = [s EXCEPT !.lf[2] = [st |-> "stub", c |-> <<>>, origin |-> "fresh", dirty |-> FALSE]]

\* Hypothesis H1: iCloud keeps an older save of this Mac as a conflict version.
SelfConflict ==
  /\ ALLOW_SELF_CONFLICT /\ s.day = 2 /\ ~s.hasConf
  /\ s.lf[2].st = "file" /\ s.hasPrev /\ s.prev # s.lf[2].c
  /\ s' = [s EXCEPT !.hasConf = TRUE, !.conf = s.prev, !.confKind = "own", !.unseen = TRUE]

\* The other Mac appends a line to the synced day-2 file after a sync.
BEditsOnline ==
  /\ ALLOW_B_EDITS_ONLINE /\ s.day = 2 /\ s.srvMain[2] /\ "b2" \notin s.used
  /\ s' = [SetSrv(s, 2, Append(s.srvC[2], "b2")) EXCEPT
             !.typed = s.typed \cup {"b2"}, !.used = s.used \cup {"b2"},
             !.lf[2].origin = IF s.lf[2].st = "file" /\ s.lf[2].origin = "fresh"
                                THEN "stale" ELSE s.lf[2].origin]

\* The other Mac edited an older copy while offline: a conflict version of the day-2 file.
BEditsOffline ==
  /\ ALLOW_B_EDITS_OFFLINE /\ s.day = 2 /\ s.srvMain[2] /\ ~s.hasConf /\ "b2" \notin s.used
  /\ s' = [s EXCEPT !.hasConf = TRUE, !.conf = Append(s.srvC[2], "b2"), !.confKind = "other",
                    !.typed = s.typed \cup {"b2"}, !.used = s.used \cup {"b2"}, !.unseen = TRUE]

\* The other Mac creates the day-2 file before it has seen this Mac's.
BCreatesOffline ==
  /\ ALLOW_B_CREATES_OFFLINE /\ s.day = 2 /\ ~s.hasBPend /\ "b2" \notin s.used
  /\ s' = [s EXCEPT !.bPend = Append(Tmpl, "b2"), !.hasBPend = TRUE, !.bCreated = TRUE,
                    !.typed = s.typed \cup {"b2"}, !.used = s.used \cup {"b2"}]

BUploads ==
  /\ s.hasBPend
  /\ IF ~s.srvMain[2]
       THEN s' = [SetSrv(s, 2, s.bPend) EXCEPT !.hasBPend = FALSE, !.bPend = <<>>]
     ELSE /\ ~s.dup
          /\ s' = [s EXCEPT !.dup = TRUE, !.dupC = s.bPend, !.dupSeen = TRUE, !.dupCopy = s.bPend,
                            !.hasBPend = FALSE, !.bPend = <<>>, !.unseen = TRUE]

DiskFills == /\ ALLOW_WRITE_FAILURE /\ ~s.diskFull /\ s' = [s EXCEPT !.diskFull = TRUE]
DiskFrees == /\ s.diskFull /\ s' = [s EXCEPT !.diskFull = FALSE]

Next ==
  \/ Type \/ RewriteTypo \/ ClickIntoText \/ GrabTitleBar \/ SwitchAway \/ SaveFires \/ PersonOpensToday
  \/ Midnight \/ Rollover \/ UnavailableRetry \/ WatcherDelivers
  \/ \E d \in Days : Upload(d) \/ Download(d)
  \/ Evict \/ SelfConflict \/ BEditsOnline \/ BEditsOffline \/ BCreatesOffline \/ BUploads
  \/ DiskFills \/ DiskFrees

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
\* Rules

TypeOK ==
  /\ s.day \in Days /\ s.shown \in Days /\ s.fp \in {"ok", "stale", "none"}
  /\ s.focus \in {"typing", "titlebar", "away"}

\* The clock alone never creates the daily file.
ClockNeverCreates == ~s.clockCreated

\* A numbered duplicate exists only when people on both Macs created the file.
DuplicateOnlyFromTwoPeople == s.dup => (s.aCreated /\ s.bCreated)

\* No typed text is lost: every typed line is in the window, a held-back edit, a local
\* file, the server's file, the duplicate, or a conflict version.
Kept ==
  Toks(s.buf) \cup (IF s.hasPend THEN Toks(s.pend) ELSE {})
  \cup UNION {Toks(s.lf[d].c) : d \in Days} \cup UNION {Toks(s.srvC[d]) : d \in Days}
  \cup Toks(s.dupC) \cup Toks(s.dupCopy) \cup Toks(s.conf) \cup Toks(s.bPend)
DailyTextKept == s.typed \subseteq Kept

\* Text typed on one day never lands in another day's file.
RightDay ==
  \A d \in Days : \A tok \in (Toks(s.lf[d].c) \cup Toks(s.srvC[d])) \cap {"a1", "a2", "r2", "b2"} : DayOf(tok) = d

NoSpuriousConflictBlock == ~s.spurious
NoRepeatedText == NoRepeat(s.buf) /\ \A d \in Days : NoRepeat(s.lf[d].c)

\* When nothing is in flight and the person is elsewhere, the window shows the file.
Settled == /\ s.shown = s.day /\ ~s.unavail /\ ~s.armed /\ ~s.unseen /\ ~s.hasConf /\ s.focus = "away"
           /\ s.lf[s.day].st = "file" /\ ~s.dupSeen
WindowMatchesDisk == Settled => (s.buf = s.lf[s.day].c /\ ~s.hasPend)

\* Reachability probe, not a rule: must BREAK, showing a duplicate can occur.
ProbeNoDuplicateEver == ~s.dup

\* Every conflict version of today's file that this Mac can merge is merged once the
\* watcher has run: no version waits while the file is readable, the Mac can write, and
\* nothing new is waiting to be reported and no save is armed (a retry reports its write).
ConflictVersionsMerged ==
  ~(s.hasConf /\ ~s.unseen /\ ~s.armed /\ s.shown = 2 /\ s.lf[2].st = "file" /\ ~s.diskFull)

=============================================================================
