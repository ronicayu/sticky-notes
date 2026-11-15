---------------------------- MODULE DailyRollover ----------------------------
\* Model (b): today's daily note on two Macs (A, B) sharing an Obsidian vault
\* in iCloud Drive, across one midnight, including creation of the file.
\* Code modelled at commit cbbec6621a3c81c6a5cd2bfa53618237bd35e156.
\* NOTES.md maps every action to file:line.
\*
\* Bodies are sets of tokens: "T" the rendered template (the same on both
\* Macs), "a1" text typed on Mac A on day 1 (just before midnight), "a2" and
\* "b2" text typed on day 2 on Mac A and Mac B, "D" a conflict divider.
\* The midnight timer and the wake observer run the same code
\* (handleMidnight), so one action stands for both.
\*
\* iCloud is modelled per file: each Mac has a local copy (none, a dataless
\* "stub", or a file), and the server has the current version, at most one
\* numbered duplicate ("<date> 2.md"), and the text held only in unresolved
\* conflict versions ("hidden"), which nothing in the daily-note code reads.

EXTENDS FiniteSets, Naturals

CONSTANTS
  TEMPLATE,                          \* a daily template is configured
  \* --- environment (TRUE = can happen) ---
  ALLOW_EVICTION,                    \* iCloud evicts a synced file to a dataless placeholder
  ALLOW_B_TYPES,                     \* the person also types on Mac B on day 2
  ALLOW_A_TYPES_DAY1,                \* the person types on Mac A just before midnight
  \* --- open defects (TRUE = the code as it is) ---
  ALLOW_DAILY_APPLY_OVER_UNSAVED,    \* reload applies disk over an armed save when not key+caret (R4)
  ALLOW_DAILY_BLIND_WRITE,           \* saveNow does not re-read before writing (R5)
  ALLOW_PLACEHOLDER_EDITABLE,        \* the "Waiting for today's note..." buffer takes typing (R6, R7)
  ALLOW_DAILY_CONFLICT_UNRESOLVED,   \* NSFileVersion conflicts in the daily folder are never merged
  \* --- bugs already fixed (TRUE = bring the old behaviour back) ---
  ALLOW_OLD_CLOCK_CREATES,           \* cbbec66: the rollover writes the template, creating the file
  ALLOW_OLD_STUB_AS_MISSING          \* BUGFIX-PLAN 0.5 / R6: an unreadable file is treated as missing

Macs  == {"A", "B"}
Days  == {1, 2}
Other(m) == IF m = "A" THEN "B" ELSE "A"
Tmpl  == IF TEMPLATE THEN {"T"} ELSE {}
Real  == {"T", "a1", "a2", "b2"}
DayOf(tok) == IF tok = "a1" THEN 1 ELSE 2
Token(m, d) == IF m = "A" THEN (IF d = 1 THEN "a1" ELSE "a2") ELSE "b2"
CanType(m, d) == (m = "A" /\ d = 1 /\ ALLOW_A_TYPES_DAY1) \/ (m = "A" /\ d = 2)
                 \/ (m = "B" /\ d = 2 /\ ALLOW_B_TYPES)

NoFile == [st |-> "none", c |-> {}, origin |-> "new", dirty |-> FALSE]
Synced(c) == [st |-> "file", c |-> c, origin |-> "fresh", dirty |-> FALSE]

VARIABLE s
vars == <<s>>

Init == s = [
  day |-> 1,
  shown   |-> [m \in Macs |-> 1],
  buf     |-> [m \in Macs |-> Tmpl],
  loaded  |-> [m \in Macs |-> Tmpl],          \* lastLoadedContent
  armed   |-> [m \in Macs |-> FALSE],
  hasPend |-> [m \in Macs |-> FALSE],
  pend    |-> [m \in Macs |-> {}],            \* pendingExternalContent
  focus   |-> [m \in Macs |-> "away"],        \* "typing" | "titlebar" | "away"
  unseen  |-> [m \in Macs |-> FALSE],
  unavail |-> [m \in Macs |-> FALSE],         \* fileUnavailable
  lf      |-> [m \in Macs |-> [d \in Days |-> IF d = 1 THEN Synced(Tmpl) ELSE NoFile]],
  dupSeen |-> [m \in Macs |-> FALSE],         \* this Mac holds a copy of the day-2 duplicate
  dupCopy |-> [m \in Macs |-> {}],            \* ... and this is its body
  srvMain |-> [d \in Days |-> d = 1],
  srvC    |-> [d \in Days |-> IF d = 1 THEN Tmpl ELSE {}],
  dup     |-> FALSE, dupC |-> {},             \* day 2 only
  hidden  |-> {},
  typed   |-> {},
  clockCreated |-> FALSE,
  userCreated  |-> [m \in Macs |-> FALSE] ]   \* day-2 file created by a person on m

-----------------------------------------------------------------------------
Contains(n, o) == o \subseteq n   \* daily edits are appends; mergeBodies checks both ways

\* ConflictResolver.mergeBodies(local:, external:)
MergeBodies(l, e) ==
  IF e \cap Real = {} \/ e = l \/ Contains(l, e) THEN l
  ELSE IF Contains(e, l) THEN e
  ELSE l \cup e \cup {"D"}

\* Write body b to Mac m's local file for day d (a create when none exists).
WriteLocal(t, m, d, b) ==
  LET f == t.lf[m][d]
  IN [t EXCEPT !.lf[m][d] = [st |-> "file", c |-> b,
                             origin |-> IF f.st = "none" THEN "new" ELSE f.origin,
                             dirty |-> TRUE],
               !.unseen[m] = TRUE]

\* saveNow (DailyNoteWindowController.swift:441-461), userTyped = this write
\* comes from something the person did.
SaveNow(t, m) ==
  IF t.unavail[m] THEN t
  ELSE LET d == t.shown[m]
           merged == IF t.hasPend[m] THEN MergeBodies(t.buf[m], t.pend[m]) ELSE t.buf[m]
           f == t.lf[m][d]
           \* proposed fix for R5: fold in a change on disk we have not loaded
           body == IF ~ALLOW_DAILY_BLIND_WRITE /\ f.st = "file" /\ f.c # t.loaded[m]
                     THEN MergeBodies(merged, f.c) ELSE merged
           t1 == [t EXCEPT !.buf[m] = body, !.hasPend[m] = FALSE, !.pend[m] = {}]
       IN IF body = t.loaded[m] THEN t1
          ELSE LET t2 == WriteLocal(t1, m, d, body)
               IN [t2 EXCEPT !.loaded[m] = body,
                             !.userCreated[m] = t.userCreated[m] \/ (d = 2 /\ f.st = "none")]

\* DailyNote.healDuplicates on Mac m's folder for the day it shows.
Heal(t, m) ==
  IF t.shown[m] = 2 /\ t.dupSeen[m] /\ t.lf[m][2].st = "file"
    THEN LET orig == t.lf[m][2].c
             merged == MergeBodies(orig, t.dupCopy[m])
             t1 == IF merged # orig THEN WriteLocal(t, m, 2, merged) ELSE t
         IN [t1 EXCEPT !.dupSeen[m] = FALSE, !.dupCopy[m] = {},
                       !.dup = FALSE, !.dupC = {}]       \* the duplicate goes to the Trash
    ELSE t

\* loadCurrentFile (DailyNoteWindowController.swift:270-313) for the day now.
Load(t, m) ==
  LET t0 == [t EXCEPT !.shown[m] = t.day]
      t1 == Heal(t0, m)
      f == t1.lf[m][t.day]
  IN IF f.st = "file"
       THEN [t1 EXCEPT !.buf[m] = f.c, !.loaded[m] = f.c, !.unavail[m] = FALSE]
     ELSE IF f.st = "stub" /\ ~ALLOW_OLD_STUB_AS_MISSING
       THEN [t1 EXCEPT !.buf[m] = {}, !.unavail[m] = TRUE]     \* "Waiting for today's note..."
     ELSE IF ALLOW_OLD_CLOCK_CREATES \/ (f.st = "stub" /\ ALLOW_OLD_STUB_AS_MISSING)
       THEN \* old code: write the template straight away, over a stub too
            LET t2 == [t1 EXCEPT !.lf[m][t.day] =
                          [st |-> "file", c |-> Tmpl,
                           origin |-> IF f.st = "stub" THEN "fresh" ELSE "new", dirty |-> TRUE],
                        !.unseen[m] = TRUE]
            IN [t2 EXCEPT !.buf[m] = Tmpl, !.loaded[m] = Tmpl, !.unavail[m] = FALSE,
                          !.clockCreated = t1.clockCreated \/ f.st = "none"]
     ELSE [t1 EXCEPT !.buf[m] = Tmpl, !.loaded[m] = Tmpl, !.unavail[m] = FALSE]  \* seedBuffer

-----------------------------------------------------------------------------
\* The person

Type(m) ==
  /\ s.focus[m] = "typing"
  /\ CanType(m, s.shown[m])
  /\ ~s.unavail[m] \/ ALLOW_PLACEHOLDER_EDITABLE
  /\ Token(m, s.shown[m]) \notin s.typed
  /\ s' = [s EXCEPT !.buf[m] = s.buf[m] \cup {Token(m, s.shown[m])},
                    !.typed = s.typed \cup {Token(m, s.shown[m])},
                    !.armed[m] = TRUE]

\* Mac B's window is only clicked into when the person works on Mac B.
ClickIntoText(m) == (m = "A" \/ ALLOW_B_TYPES) /\ s.focus[m] # "typing"
                    /\ s' = [s EXCEPT !.focus[m] = "typing"]
GrabTitleBar(m)  == s.focus[m] = "typing" /\ s' = [s EXCEPT !.focus[m] = "titlebar"]

\* windowDidResignKey
SwitchAway(m) ==
  /\ s.focus[m] # "away"
  /\ s' = IF s.hasPend[m] THEN SaveNow([s EXCEPT !.focus[m] = "away"], m)
          ELSE [s EXCEPT !.focus[m] = "away"]

\* The 0.4 s debounce fires (also flushPendingSave on quit / hide).
SaveFires(m) ==
  /\ s.armed[m]
  /\ s' = SaveNow([s EXCEPT !.armed[m] = FALSE], m)

\* show(userInitiated: true): menu bar, hotkey, notes panel.
PersonOpensToday(m) ==
  /\ s.shown[m] = s.day /\ ~s.unavail[m]
  /\ s.lf[m][s.day].st = "none"
  /\ LET t == WriteLocal(s, m, s.day, s.buf[m])
     IN s' = [t EXCEPT !.loaded[m] = s.buf[m],
                       !.userCreated[m] = s.userCreated[m] \/ s.day = 2]

-----------------------------------------------------------------------------
\* Clocks and the watcher

Midnight == s.day = 1 /\ s' = [s EXCEPT !.day = 2]

\* handleMidnight, from the midnight timer, the wake observer, or show().
Rollover(m) ==
  /\ s.shown[m] < s.day
  /\ s' = Load(SaveNow([s EXCEPT !.armed[m] = FALSE], m), m)

\* The 5 s retry while waiting for a download (scheduleUnavailableRetry).
UnavailableRetry(m) ==
  /\ s.unavail[m]
  /\ s' = Load(s, m)

\* reloadIfExternallyChanged (DailyNoteWindowController.swift:336-362).
WatcherDelivers(m) ==
  /\ s.unseen[m]
  /\ LET t == Heal([s EXCEPT !.unseen[m] = FALSE], m)
         f == t.lf[m][t.shown[m]]
         caret == t.focus[m] = "typing"
         defer == IF ALLOW_DAILY_APPLY_OVER_UNSAVED THEN caret ELSE caret \/ t.armed[m]
     IN s' = IF f.st # "file" THEN t
             ELSE IF t.unavail[m]
               THEN [t EXCEPT !.unavail[m] = FALSE, !.loaded[m] = f.c, !.buf[m] = f.c]
             ELSE IF f.c = t.loaded[m] THEN t
             ELSE IF defer THEN [t EXCEPT !.hasPend[m] = TRUE, !.pend[m] = f.c]
             ELSE [t EXCEPT !.loaded[m] = f.c, !.buf[m] = f.c]

-----------------------------------------------------------------------------
\* iCloud

SetSrv(t, d, c) == [t EXCEPT !.srvMain[d] = TRUE, !.srvC[d] = c]

\* Mac m uploads its dirty local file for day d.
Upload(m, d) ==
  /\ s.lf[m][d].st = "file" /\ s.lf[m][d].dirty
  /\ LET f == s.lf[m][d]
         o == Other(m)
         staleOther(t) == IF t.lf[o][d].st = "file" /\ t.lf[o][d].origin = "fresh"
                            THEN [t EXCEPT !.lf[o][d].origin = "stale"] ELSE t
     IN IF ~s.srvMain[d]
          THEN s' = SetSrv([s EXCEPT !.lf[m][d] = Synced(f.c)], d, f.c)
        ELSE IF f.origin = "new"
          THEN \* two independent creates: iCloud keeps both, ours becomes "<date> 2"
               /\ d = 2 /\ ~s.dup
               /\ s' = [s EXCEPT !.dup = TRUE, !.dupC = f.c,
                                 !.dupSeen = [x \in Macs |-> TRUE],
                                 !.dupCopy = [x \in Macs |-> f.c],
                                 !.lf[m][d] = Synced(s.srvC[d]),
                                 !.unseen = [x \in Macs |-> TRUE]]
        ELSE IF f.origin = "fresh"
          THEN s' = staleOther(SetSrv([s EXCEPT !.lf[m][d] = Synced(f.c)], d, f.c))
        ELSE \* edited a stale copy: NSFileVersion conflict
             IF ~ALLOW_DAILY_CONFLICT_UNRESOLVED
               THEN LET m2 == MergeBodies(f.c, s.srvC[d])
                    IN s' = staleOther(SetSrv([s EXCEPT !.lf[m][d] = Synced(m2),
                                                        !.unseen[m] = TRUE], d, m2))
             ELSE \E oursWins \in BOOLEAN :
                    IF oursWins
                      THEN s' = staleOther(SetSrv([s EXCEPT !.lf[m][d] = Synced(f.c),
                                    !.hidden = s.hidden \cup (s.srvC[d] \ f.c)], d, f.c))
                      ELSE s' = [s EXCEPT !.lf[m][d] = Synced(s.srvC[d]),
                                    !.hidden = s.hidden \cup (f.c \ s.srvC[d]),
                                    !.unseen[m] = TRUE]

\* Mac m downloads the server's version (none yet, a stub, or a stale clean copy).
Download(m, d) ==
  /\ s.srvMain[d]
  /\ LET f == s.lf[m][d] IN
       /\ ~f.dirty
       /\ (f.st \in {"none", "stub"} \/ f.origin = "stale")
       /\ s' = [s EXCEPT !.lf[m][d] = Synced(s.srvC[d]), !.unseen[m] = TRUE]

Evict(m, d) ==
  /\ ALLOW_EVICTION /\ d = 2
  /\ s.lf[m][d].st = "file" /\ ~s.lf[m][d].dirty /\ s.lf[m][d].origin = "fresh"
  /\ s' = [s EXCEPT !.lf[m][d] = [st |-> "stub", c |-> {}, origin |-> "fresh", dirty |-> FALSE]]

\* The other Mac's trashing of the duplicate reaches Mac m.
DupGone(m) ==
  /\ s.dupSeen[m] /\ ~s.dup
  /\ s' = [s EXCEPT !.dupSeen[m] = FALSE, !.dupCopy[m] = {}]

Next ==
  \/ Midnight
  \/ \E m \in Macs : \/ Type(m) \/ ClickIntoText(m) \/ GrabTitleBar(m) \/ SwitchAway(m)
                     \/ SaveFires(m) \/ PersonOpensToday(m) \/ Rollover(m)
                     \/ UnavailableRetry(m) \/ WatcherDelivers(m) \/ DupGone(m)
  \/ \E m \in Macs, d \in Days : Upload(m, d) \/ Download(m, d) \/ Evict(m, d)

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
\* Rules

\* The clock alone never creates the daily file (cbbec66).
ClockNeverCreates == ~s.clockCreated

\* A duplicate of today's note exists only when people on both Macs created it.
DuplicateOnlyFromTwoPeople == s.dup => (s.userCreated["A"] /\ s.userCreated["B"])

\* No typed text is lost: every typed token is in a window, a deferred edit,
\* a local file, the server's file, or the duplicate (not only in a conflict
\* version nobody reads).
Kept ==
  UNION {s.buf[m] \cup s.pend[m] : m \in Macs}
  \cup UNION {s.lf[m][d].c : m \in Macs, d \in Days}
  \cup UNION {s.srvC[d] : d \in Days} \cup s.dupC
  \cup UNION {s.dupCopy[m] : m \in Macs}
DailyTextKept == s.typed \subseteq Kept

\* Text typed on one day never lands in another day's file.
RightDay ==
  \A m \in Macs, d \in Days :
    \A tok \in (s.lf[m][d].c \cup s.srvC[d]) \cap {"a1", "a2", "b2"} : DayOf(tok) = d

\* Reachability probe, not a rule: must BREAK, showing a duplicate can occur.
ProbeNoDuplicateEver == ~s.dup

=============================================================================
