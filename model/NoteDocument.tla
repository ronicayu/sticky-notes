---------------------------- MODULE NoteDocument -----------------------------
\* Model (a), v2: one sticky note, edited through NoteDocument, in Obsidian
\* vault mode with the vault in iCloud Drive. One Mac, in turn with a second
\* Mac that only acts through the file system and iCloud.
\* Code modelled: commit c16cef1 (branch masterpiece). NOTES.md maps every
\* action to file:line at that commit.
\*
\* Switch convention (reversed from v1): every ALLOW_OLD_* constant is FALSE for
\* the code as it is now. TRUE brings back one behaviour that a commit since
\* the first model run fixed, so the regress-*.cfg configs can show that the
\* model still sees that bug.
\*
\* Text: a body is a SEQUENCE of line tokens (LineMerge.tla). Tokens:
\*   "c"  captured text the note was created with (clipboard, Service)
\*   "a", "b"  lines the person typed, in that order
\*   "r"  the first line after a backspace or mid-line edit (replaces it)
\*   "x", "y"  lines another writer (Obsidian, the other Mac) appended
\*   "D"  a "Conflicted copy" divider
\* The file's fingerprint is modelled as a relation, not a value: `fp` says
\* whether the document's stored fingerprint matches the file now ("ok"), is
\* behind it ("stale"), or the document expects no file ("none").

EXTENDS LineMerge, FiniteSets, Naturals, Sequences

CONSTANTS
  \* --- shape of the run ---
  PREFILLED,                      \* a note created with captured text "c"
  CAPTURE_WRITE_FAILS,            \* ... whose creating write failed
  TWO_EXT,                        \* two different outside lines ("x", "y") instead of one
  \* --- environment (TRUE = can happen) ---
  ALLOW_ERASE,                    \* the person deletes all the text
  ALLOW_EXTERNAL_EDIT,            \* Obsidian / the other Mac appends a line to the file
  ALLOW_META_WRITE,               \* frontmatter-only rewrite: same text, new bytes
  ALLOW_OBSIDIAN_STALE_REWRITE,   \* Obsidian writes back an older copy of our text
  ALLOW_ICLOUD_SELF_CONFLICT,     \* iCloud keeps an older write of THIS Mac as a conflict version
  ALLOW_OTHER_MAC_CONFLICT,       \* the other Mac, offline, edited an older copy: conflict version
  ALLOW_SWEEP,                    \* the conflict sweep runs
  ALLOW_EXTERNAL_MOVE,            \* the other Mac archives / trashes / deletes the file
  ALLOW_UNLISTED,                 \* the store cannot list / read the note's file for a while
  ALLOW_WRITE_FAILURE,            \* writes fail for a while (disk full, permission)
  ALLOW_PLACEHOLDER,              \* an iCloud placeholder sits in a notes folder: where the note went is unknown
  ALLOW_PANEL,                    \* the notes panel archives the note
  ALLOW_LIFECYCLE,                \* Quit, Relaunch, restore, delete, 30 days pass
  PROMPT_WATCHER,                 \* regress configs: an outside write is reported before the app writes
  \* --- open defects found by this model (TRUE = the code as it is; FALSE = the proposed fix) ---
  ALLOW_OWN_COPY_BLOCK,           \* N1: an outside rewrite back to an older copy of our text is appended as a conflict
  ALLOW_BLANK_WINNER_BLOCK,       \* N2: a blank file is not replaced by a conflict version that has text
  ALLOW_LINEAGE_RESET,            \* N4: the write lineage ends at a foreign read or a relaunch, so an older own save merges as a conflict
  ALLOW_LINEAGE_NEEDS_NEWEST,     \* N5: an older own save is dropped only while the file is exactly our newest write
  ALLOW_CLOSE_REFUSED_UNREADABLE, \* N3: the person's close is refused for good while the note's file cannot be read
  \* --- bugs fixed before ea21f7a (TRUE = bring the old behaviour back) ---
  ALLOW_OLD_NO_QUIT_FLUSH,        \* 0.1  quit dropped pending edits
  ALLOW_OLD_PURGE_BY_MTIME,       \* 0.2  purge used the modification date
  ALLOW_OLD_ARCHIVE_NO_FLUSH,     \* 0.3  close archived without writing the last typing
  ALLOW_OLD_SAVE_NO_MERGE,        \* 0.4  a save overwrote a deferred outside edit
  ALLOW_OLD_NO_ECHO_FILTER,       \* R1 r2: own echo was merged as an outside edit
  ALLOW_OLD_CLOSE_NO_MERGE,       \* R3 r2: close did not merge the deferred edit
  ALLOW_OLD_APPLY_WHEN_NOT_EDITING, \* 6cbd1f0: change applied over unsaved typing when the caret was out
  \* --- findings F1-F6 and review bugs fixed since the first model run ---
  ALLOW_OLD_SUBSTRING_MERGE,      \* F1: merge appended any version that was not a substring
  ALLOW_OLD_NO_LINEAGE,           \* F1/H1: an older save of this Mac was merged as a conflict
  ALLOW_OLD_UNBASED_MERGE,        \* review of 1.1: merge without the base the document last saw
  ALLOW_OLD_STALE_FP_ECHO,        \* review of 1.1: a frontmatter-only write left the fingerprint stale
  ALLOW_OLD_STALE_PERSISTED_MARK, \* F2: adopting an outside version left the base stale
  ALLOW_OLD_EMPTY_DISCARD_IGNORES_DISK, \* F3: "empty" judged from the window only
  ALLOW_OLD_HARD_DELETE,          \* F3: discard unlinked the file
  ALLOW_OLD_BLIND_WRITE,          \* F4: a save did not check the file first
  ALLOW_OLD_GONE_AS_SAVED,        \* F5: a save to a note that left the folder counted as saved
  ALLOW_OLD_RECONCILE_DROPS,      \* F5: reconcile closed the window and dropped unsaved typing
  ALLOW_OLD_UNLISTED_IS_GONE,     \* R3: a listing miss closed the window
  ALLOW_OLD_PANEL_NO_FLUSH,       \* F5/R9: the panel archived without the window's flush
  ALLOW_OLD_MARK_BEFORE_WRITE,    \* F6: a failed write counted as saved
  ALLOW_OLD_SWEEP_NO_FLUSH,       \* review of 1.1: conflict sweep without the window's write first
  ALLOW_OLD_WRITE_AT_CREATION,    \* R10: a blank new note was written at creation
  ALLOW_OLD_CAPTURE_NO_ARM,       \* review of 1.2: a failed capture write armed no save
  ALLOW_OLD_STRANDED_CLOSE_REFUSED, \* review of 1.2/1.3: a close of a stranded note was refused for good
  ALLOW_OLD_TRASH_NO_STAMP,       \* review of 1.2/1.3: a write into a trashed file kept the old deletion date
  ALLOW_OLD_RESURRECT             \* a save to a note that left the folder wrote the file again

AppendTokens == <<"a", "b">>
FirstLine    == IF PREFILLED THEN "c" ELSE "a"
ExtEdits     == IF TWO_EXT THEN {"x", "y"} ELSE {"x"}
Real         == {"c", "a", "b", "r"} \cup Outside
Folders      == {"active", "archive", "trash"}

VARIABLE s
vars == <<s>>

Blank(b) == b = <<>>

\* The state before anything happens. A new note has no file; a captured one is
\* written by the store at once (DeskController.makeNote -> store.save).
Init0 ==
  [ app |-> "running", win |-> "open", loc |-> {}, listed |-> TRUE, diskFull |-> FALSE, ph |-> FALSE, flaky |-> 2,
    disk |-> <<>>, fp |-> "none", hasFile |-> FALSE, diskOwn |-> FALSE,
    buf |-> <<>>, base |-> <<>>, hasPend |-> FALSE, pend |-> <<>>,
    armed |-> FALSE, unsaved |-> FALSE, touched |-> FALSE, focus |-> "typing",
    stranded |-> FALSE, actGone |-> FALSE, unseen |-> FALSE, reconDue |-> FALSE,
    lin |-> {}, linNew |-> <<>>, prev |-> <<>>, hasPrev |-> FALSE,
    conflict |-> <<>>, hasConf |-> FALSE, confKind |-> "none",
    typed |-> {}, used |-> {}, extRemoved |-> {}, rec |-> <<>>, recDir |-> {},
    spurious |-> FALSE, falseClose |-> FALSE, blankUntouched |-> FALSE,
    purgedEarly |-> FALSE, legitGone |-> FALSE, trashAge |-> "fresh",
    trashWriteAge |-> "none", mtimeOld |-> FALSE ]

Init ==
  /\ IF ALLOW_OLD_WRITE_AT_CREATION /\ ~PREFILLED
       THEN s = [Init0 EXCEPT !.loc = {"active"}, !.fp = "ok", !.hasFile = TRUE,
                              !.unseen = TRUE, !.blankUntouched = TRUE,
                              !.lin = {<<>>}, !.linNew = <<>>, !.diskOwn = TRUE]
     ELSE IF PREFILLED /\ CAPTURE_WRITE_FAILS
       THEN s = [Init0 EXCEPT !.buf = <<"c">>, !.base = <<"c">>, !.typed = {"c"},
                              !.armed = ~ALLOW_OLD_CAPTURE_NO_ARM, !.diskFull = TRUE]
     ELSE IF PREFILLED
       THEN s = [Init0 EXCEPT !.loc = {"active"}, !.fp = "ok", !.hasFile = TRUE,
                              !.disk = <<"c">>, !.buf = <<"c">>, !.base = <<"c">>,
                              !.typed = {"c"}, !.used = {"c"}, !.unseen = TRUE, !.lin = {<<"c">>},
                              !.linNew = <<"c">>, !.diskOwn = TRUE]
     ELSE s = Init0

-----------------------------------------------------------------------------
\* Helpers on a state t

Running(t) == t.app = "running"
HasUnsaved(t) == t.armed \/ t.buf # t.base
HoldsText(t) == t.unsaved \/ t.buf # t.base      \* holdsTextNoFileHas
Readable(t) == "active" \in t.loc /\ t.listed     \* the store can read the active file
Out(t, ok) == [st |-> t, ok |-> ok]

\* A read of the file ends the write lineage unless the file holds our newest write
\* (NoteStore.readMainSnapshot, DailyFile.read).
Rd(t) == IF ALLOW_LINEAGE_RESET /\ t.lin # {} /\ t.disk # t.linNew THEN [t EXCEPT !.lin = {}] ELSE t
NewestOwn(t) == t.lin # {} /\ t.disk = t.linNew

\* This app writes body b to the active file (create or replace): fingerprint
\* taken, lineage recorded, the watcher will report it.
Wr(t, b) ==
  [t EXCEPT !.disk = b, !.fp = "ok", !.hasFile = TRUE, !.loc = t.loc \cup {"active"},
            !.hasPrev = t.hasPrev \/ t.diskOwn,
            !.prev = IF t.diskOwn THEN t.disk ELSE t.prev, !.diskOwn = TRUE,
            !.lin = t.lin \cup {b}, !.linNew = b, !.unseen = TRUE, !.mtimeOld = FALSE,
            !.blankUntouched = t.blankUntouched \/ (Blank(b) /\ ~t.touched)]

MarkPersisted(t) == [t EXCEPT !.base = t.buf, !.unsaved = FALSE, !.stranded = FALSE]

\* NoteDocument.mergePendingExternal after the outside version `ext` was chosen.
\* `known`: its fingerprint is known, so the document adopts it.
MergeIn(t, ext, known) ==
  LET r == IF ALLOW_OLD_UNBASED_MERGE THEN MergeVersions(t.buf, ext, ALLOW_OLD_SUBSTRING_MERGE, ~ALLOW_BLANK_WINNER_BLOCK)
           ELSE IF ~ALLOW_OWN_COPY_BLOCK /\ t.hasPrev /\ ext = t.prev
             THEN [c |-> t.buf, blk |-> FALSE, sp |-> FALSE]      \* proposed fix for N1
           ELSE ThreeWay(t.base, t.buf, ext)
  IN [t EXCEPT !.buf = r.c, !.base = ext, !.hasPend = FALSE, !.pend = <<>>,
               !.fp = IF known THEN "ok" ELSE t.fp,
               !.spurious = t.spurious \/ r.sp]

\* mergePendingExternal(): a held-back version is replaced by a fresh read when the
\* file can be read.
MergePend(t) ==
  IF ~t.hasPend THEN t
  ELSE IF Readable(t) THEN MergeIn(Rd(t), t.disk, TRUE)
  ELSE MergeIn(t, t.pend, FALSE)

\* persist() meeting a changed file: the on-disk version is merged into the buffer.
MergeFromDisk(t) == MergeIn(Rd(t), t.disk, TRUE)

Closed(t) == [t EXCEPT !.win = "closed", !.buf = <<>>, !.base = <<>>, !.armed = FALSE,
                       !.hasPend = FALSE, !.pend = <<>>, !.focus = "away", !.touched = FALSE,
                       !.unsaved = FALSE, !.stranded = FALSE, !.actGone = FALSE]

Opened(t) == [t EXCEPT !.win = "open", !.buf = t.disk, !.base = t.disk, !.fp = "ok",
                       !.hasFile = TRUE, !.hasPend = FALSE, !.pend = <<>>, !.armed = FALSE,
                       !.unsaved = FALSE, !.touched = FALSE, !.focus = "away",
                       !.stranded = FALSE, !.actGone = FALSE]

\* --- persist() -------------------------------------------------------------
\* Fail: nothing reached disk; a retry is armed. The old code marked the buffer saved first.
Fail(t) == IF ALLOW_OLD_MARK_BEFORE_WRITE THEN Out(MarkPersisted(t), TRUE)
           ELSE Out([t EXCEPT !.armed = TRUE], FALSE)

Stranded(t) == Out([t EXCEPT !.stranded = TRUE, !.armed = TRUE], FALSE)

Saved(t) == Out([MarkPersisted(Wr(t, t.buf)) EXCEPT !.actGone = FALSE], TRUE)

\* The note's file is gone from the active folder (NoteDocument.persist case .gone,
\* keepTextElsewhere). loc is archive, trash or none.
Keep(t) ==
  IF t.diskFull THEN Stranded(t)
  ELSE IF t.loc \in {{"archive"}, {"trash"}} THEN
    \* merge what the file there holds into the buffer, write it over exactly that file
    LET m == MergeIn(Rd([t EXCEPT !.hasPend = TRUE, !.pend = t.disk]), t.disk, TRUE)
        intrash == t.loc = {"trash"}
        k == [m EXCEPT !.disk = m.buf, !.unseen = TRUE, !.reconDue = TRUE, !.mtimeOld = FALSE,
                       !.trashAge = IF intrash /\ ~ALLOW_OLD_TRASH_NO_STAMP THEN "fresh" ELSE m.trashAge,
                       !.trashWriteAge = IF intrash THEN "fresh" ELSE m.trashWriteAge]
    IN Out([MarkPersisted(k) EXCEPT !.actGone = TRUE], TRUE)
  ELSE IF t.ph THEN Stranded(t)       \* whereIs: a placeholder is there, so the note may only be downloading
  ELSE \* nowhere: a recovered copy in .trash under a new id
    Out([MarkPersisted(t) EXCEPT !.rec = t.buf, !.actGone = TRUE, !.reconDue = TRUE], TRUE)

GonePath(t) ==
  IF ALLOW_OLD_GONE_AS_SAVED THEN Out(MarkPersisted(t), TRUE)
  ELSE IF ~HoldsText(t) THEN Out(MarkPersisted(t), TRUE)
  ELSE IF ALLOW_OLD_RESURRECT THEN Saved(t)
  ELSE Keep(t)

Persist(t) ==
  IF "active" \in t.loc /\ ~t.listed THEN Fail(t)
  ELSE IF "active" \in t.loc THEN
    IF t.diskFull THEN Fail(IF t.fp # "ok" /\ ~ALLOW_OLD_BLIND_WRITE THEN MergeFromDisk(t) ELSE t)
    ELSE IF t.fp = "ok" \/ ALLOW_OLD_BLIND_WRITE THEN Saved(t)
    ELSE Saved(MergeFromDisk(t))
  ELSE IF t.loc = {} /\ ~t.hasFile /\ t.fp = "none" THEN     \* a new note's first write
    IF t.diskFull THEN Fail(t) ELSE Saved(t)
  ELSE IF ~t.listed THEN Fail(t)
  ELSE GonePath(t)

\* --- closing -----------------------------------------------------------------
\* NoteDocument.foldInOutsideText: a blank note takes in outside text before it is discarded.
FoldOutside(t) ==
  LET m == MergePend(t)
  IN IF Blank(m.buf) /\ ~m.hasPend /\ Readable(m) /\ ~Blank(m.disk) /\ m.disk # m.base
       THEN MergeIn(Rd(m), m.disk, TRUE) ELSE m

\* NoteStore.discardActive (to .trash, or unlinked in the old code) and the window closing.
Discard(t) ==
  LET gone == "active" \in t.loc
  IN Closed([t EXCEPT
       !.loc = IF ~gone THEN t.loc
               ELSE IF ALLOW_OLD_HARD_DELETE THEN t.loc \ {"active"}
               ELSE (t.loc \ {"active"}) \cup {"trash"},
       !.trashAge = "fresh", !.trashWriteAge = "none",
       !.mtimeOld = IF ALLOW_OLD_PURGE_BY_MTIME THEN t.mtimeOld ELSE FALSE,
       !.reconDue = TRUE, !.unseen = IF gone THEN TRUE ELSE t.unseen])

\* NoteDocument.close(.archive): result st, closed = the window is gone.
CloseArchive(t0) ==
  LET t == [t0 EXCEPT !.armed = FALSE]
      f == IF ALLOW_OLD_EMPTY_DISCARD_IGNORES_DISK \/ ALLOW_OLD_CLOSE_NO_MERGE THEN t ELSE FoldOutside(t)
  IN IF Blank(f.buf) THEN [st |-> Discard(f), closed |-> TRUE]
     ELSE LET m == IF ALLOW_OLD_CLOSE_NO_MERGE \/ ALLOW_OLD_ARCHIVE_NO_FLUSH THEN f ELSE MergePend(f)
              p == IF ALLOW_OLD_ARCHIVE_NO_FLUSH THEN Out(m, TRUE) ELSE Persist(m)
          IN IF ~p.ok THEN [st |-> p.st, closed |-> FALSE]
             ELSE [st |-> Closed([p.st EXCEPT
                         !.loc = IF "active" \in p.st.loc THEN (p.st.loc \ {"active"}) \cup {"archive"}
                                 ELSE p.st.loc,
                         !.reconDue = TRUE, !.unseen = TRUE]),
                   closed |-> TRUE]

\* NoteDocument.close(.externalDeletion) and, if refused, DeskController.closeKeepingText
\* (a recovery file outside the storage root, then close(.externalDeletionTextKept)).
CloseGone(t0) ==
  LET t == [t0 EXCEPT !.armed = FALSE]
      m == IF HoldsText(t) THEN MergePend(t) ELSE t
      p == IF HoldsText(t) THEN Persist(m) ELSE Out(m, TRUE)
  IN IF p.ok THEN [st |-> Closed(p.st), closed |-> TRUE]
     ELSE IF p.st.diskFull THEN [st |-> p.st, closed |-> FALSE]     \* recovery.write fails too
     ELSE [st |-> Closed([p.st EXCEPT !.recDir = p.st.recDir \cup Toks(p.st.buf)]), closed |-> TRUE]

\* The person's close, with DeskController's onCloseRefused: a stranded note takes the
\* recovery way out.
PersonClose(t0) ==
  LET r == CloseArchive(t0)
      way == \/ (r.st.stranded /\ ~ALLOW_OLD_STRANDED_CLOSE_REFUSED)
             \/ (~ALLOW_CLOSE_REFUSED_UNREADABLE /\ ~r.st.listed)
  IN IF r.closed \/ ~way THEN r
     ELSE IF r.st.diskFull THEN r
     ELSE [st |-> Closed([r.st EXCEPT !.recDir = r.st.recDir \cup Toks(r.st.buf)]), closed |-> TRUE]

\* --- the window hears a file change (NoteDocument.storeDidChange / externalChange) --------
\* The window shows an outside version.
Apply(t) ==
  [t EXCEPT !.buf = t.disk, !.fp = "ok",
            !.base = IF ALLOW_OLD_STALE_PERSISTED_MARK THEN t.base ELSE t.disk]

ExternalChange(t0) ==
  LET t == Rd(t0)
      echo == ~ALLOW_OLD_NO_ECHO_FILTER /\ t.disk = t.base
      defer == IF ALLOW_OLD_APPLY_WHEN_NOT_EDITING THEN t.focus = "typing"
               ELSE HasUnsaved(t) \/ t.focus = "typing"
  IN IF echo THEN IF ALLOW_OLD_STALE_FP_ECHO THEN t ELSE [t EXCEPT !.fp = "ok"]
     ELSE IF t.disk = t.buf
       THEN [t EXCEPT !.base = t.disk, !.fp = "ok"]
     ELSE IF defer THEN [t EXCEPT !.hasPend = TRUE, !.pend = t.disk]
     ELSE Apply(t)

Hear(t) == IF t.win = "open" /\ Readable(t) THEN ExternalChange([t EXCEPT !.hasFile = TRUE]) ELSE t

-----------------------------------------------------------------------------
\* Guard on every step in which the app writes the note.
MayWrite == ~PROMPT_WATCHER \/ ~(s.unseen /\ ~s.diskOwn)

WinOpen == s.app = "running" /\ s.win = "open"

\* The person ------------------------------------------------------------------

\* NoteDocument.edit: an append, or a backspace / mid-line edit of the first line.
Type ==
  /\ WinOpen /\ s.focus = "typing"
  /\ \/ \E i \in 1..Len(AppendTokens) :
          /\ AppendTokens[i] \notin s.used
          /\ (IF i = 1 THEN TRUE ELSE AppendTokens[i - 1] \in s.used)
          /\ s' = [s EXCEPT !.buf = Append(s.buf, AppendTokens[i]),
                            !.typed = s.typed \cup {AppendTokens[i]},
                            !.used = s.used \cup {AppendTokens[i]},
                            !.armed = TRUE, !.touched = TRUE, !.unsaved = TRUE]
     \/ /\ s.buf # <<>> /\ s.buf[1] = FirstLine /\ "r" \notin s.used
        /\ s' = [s EXCEPT !.buf = <<"r">> \o TailOf(s.buf, <<FirstLine>>),
                          !.typed = (s.typed \ {FirstLine}) \cup {"r"}, !.used = s.used \cup {"r"},
                          !.armed = TRUE, !.touched = TRUE, !.unsaved = TRUE]

EraseAll ==
  /\ ALLOW_ERASE /\ WinOpen /\ s.focus = "typing" /\ s.buf # <<>>
  /\ s' = [s EXCEPT !.buf = <<>>, !.typed = {}, !.armed = TRUE, !.touched = TRUE,
                    !.unsaved = TRUE]

ClickIntoText == /\ WinOpen /\ s.focus # "typing" /\ s' = [s EXCEPT !.focus = "typing"]

\* Clicking the note's own title bar drops first responder; the window stays key.
GrabTitleBar == /\ WinOpen /\ s.focus = "typing" /\ s' = [s EXCEPT !.focus = "titlebar"]

\* windowDidResignKey: an untouched empty note is swept up (close(.discard)); else blur().
SwitchAway ==
  /\ MayWrite /\ WinOpen /\ s.focus # "away"
  /\ LET t == [s EXCEPT !.focus = "away"]
     IN IF ~s.touched /\ Blank(s.buf)
          THEN LET f == FoldOutside([t EXCEPT !.armed = FALSE])
               IN s' = IF Blank(f.buf) THEN Discard(f) ELSE f          \* text arrived: it stays
        ELSE IF s.hasPend
          THEN s' = Persist(MergePend(t)).st
        ELSE s' = t

\* The debounced save fires (also a retry after a failed write).
SaveFires ==
  /\ MayWrite /\ WinOpen /\ s.armed
  /\ LET t == [s EXCEPT !.armed = FALSE]
         m == IF ALLOW_OLD_SAVE_NO_MERGE THEN [t EXCEPT !.hasPend = FALSE, !.pend = <<>>] ELSE MergePend(t)
     IN s' = Persist(m).st

\* The close button.
CloseNote ==
  /\ MayWrite /\ WinOpen
  /\ s' = PersonClose(s).st

\* DeskController.archiveNote (notes panel): through the window, or straight to the store.
PanelArchive ==
  /\ MayWrite /\ ALLOW_PANEL /\ s.app = "running" /\ s.loc = {"active"} /\ s.focus = "away"
  /\ IF s.win = "open" /\ ~ALLOW_OLD_PANEL_NO_FLUSH
       THEN s' = PersonClose(s).st
       ELSE s' = [s EXCEPT !.loc = {"archive"}, !.unseen = TRUE, !.reconDue = TRUE]

\* applicationShouldTerminate: flush every window; a window whose write fails gets a
\* recovery file; if that fails too the person chooses Keep Trying (no step).
Quit ==
  /\ MayWrite /\ s.app = "running"
  /\ LET t0 == [s EXCEPT !.armed = FALSE]
         flush == s.win = "open" /\ s.armed /\ ~ALLOW_OLD_NO_QUIT_FLUSH
         p == IF flush THEN Persist(MergePend(t0)) ELSE Out(s, TRUE)
         recOk == ~p.st.diskFull
     IN /\ p.ok \/ recOk
        /\ s' = [Closed([p.st EXCEPT !.recDir = IF p.ok THEN p.st.recDir ELSE p.st.recDir \cup Toks(p.st.buf)])
                   EXCEPT !.app = "quit", !.unseen = FALSE, !.reconDue = FALSE,
                   !.lin = IF ALLOW_LINEAGE_RESET THEN {} ELSE p.st.lin]

\* Launch: purge expired trash, then restoreActiveNotes.
Relaunch ==
  /\ ALLOW_LIFECYCLE /\ s.app = "quit"
  /\ LET due   == IF ALLOW_OLD_PURGE_BY_MTIME THEN s.mtimeOld ELSE s.trashAge = "old"
         purge == s.loc = {"trash"} /\ due
         t == [s EXCEPT !.app = "running", !.listed = TRUE,
                        !.loc = IF purge THEN {} ELSE s.loc,
                        !.purgedEarly = s.purgedEarly \/ (purge /\ (s.trashAge = "fresh" \/ s.trashWriteAge = "fresh")),
                        !.legitGone = s.legitGone \/ (purge /\ s.trashAge = "old" /\ s.trashWriteAge # "fresh")]
     IN s' = IF t.loc = {"active"} THEN Opened(t) ELSE t

Restore ==
  /\ ALLOW_LIFECYCLE /\ s.app = "running" /\ s.loc = {"archive"}
  /\ s' = [s EXCEPT !.loc = {"active"}, !.unseen = TRUE, !.reconDue = TRUE]

DeleteForever ==
  /\ ALLOW_LIFECYCLE /\ s.app = "running" /\ s.loc = {"archive"}
  /\ s' = [s EXCEPT !.loc = {"trash"}, !.trashAge = "fresh", !.trashWriteAge = "none",
                    !.mtimeOld = IF ALLOW_OLD_PURGE_BY_MTIME THEN s.mtimeOld ELSE FALSE]

RestoreFromTrash ==
  /\ ALLOW_LIFECYCLE /\ s.app = "running" /\ s.loc = {"trash"}
  /\ s' = [s EXCEPT !.loc = {"archive"}, !.trashAge = "fresh", !.trashWriteAge = "none"]

MonthPasses ==
  /\ ALLOW_LIFECYCLE
  /\ (~s.mtimeOld \/ (s.loc = {"trash"} /\ (s.trashAge = "fresh" \/ s.trashWriteAge = "fresh")))
  /\ s' = [s EXCEPT !.mtimeOld = TRUE,
                    !.trashAge = IF s.loc = {"trash"} THEN "old" ELSE s.trashAge,
                    !.trashWriteAge = IF s.trashWriteAge = "fresh" THEN "old" ELSE s.trashWriteAge]

\* The watcher and the desk ----------------------------------------------------------

\* NoteStore.didChange reaches the window: NoteDocument.storeDidChange.
WindowHears ==
  /\ s.app = "running" /\ s.unseen
  /\ s' = Hear([s EXCEPT !.unseen = FALSE])

\* DeskController.reconcileOpenWindows, which runs a moment after didChange.
Reconcile ==
  /\ s.app = "running" /\ s.reconDue
  /\ LET t == [s EXCEPT !.reconDue = FALSE]
     IN IF ~t.listed
          THEN \* listActive() is nil: nothing is said about any note
               IF ALLOW_OLD_UNLISTED_IS_GONE /\ t.win = "open"
                 THEN s' = [Closed(t) EXCEPT !.falseClose = ("active" \in t.loc)]
                 ELSE s' = t
        ELSE IF t.win = "open" /\ "active" \notin t.loc
          THEN IF ALLOW_OLD_RECONCILE_DROPS
                 THEN s' = Closed(t)
               ELSE IF t.hasFile /\ ~(t.loc = {} /\ t.ph)  \* isGone: whereIs says archived, trashed or missing
                 THEN s' = CloseGone(t).st
               ELSE s' = t
        ELSE IF t.win = "closed" /\ t.loc = {"active"}
          THEN s' = Opened(t)                         \* presentWindow(activate: false)
        ELSE s' = t

\* The conflict sweep: NoteStore.resolveConflict with beforeResolvingConflicts.
ConflictSweep ==
  /\ ALLOW_SWEEP /\ s.app = "running" /\ s.hasConf /\ s.listed
  /\ s.loc \in {{"active"}, {"archive"}}
  /\ LET flushed == IF s.win = "open" /\ s.armed /\ ~ALLOW_OLD_SWEEP_NO_FLUSH
                      THEN Persist(MergePend([s EXCEPT !.armed = FALSE]))
                      ELSE Out(s, TRUE)
     IN IF ~flushed.ok
          THEN s' = flushed.st                       \* the versions wait for a later sweep
        ELSE
          \E conflictWins \in BOOLEAN :
            /\ (conflictWins => s.confKind = "ext")  \* an older own save is never the newest
            /\ LET t == Rd(flushed.st)
                   dropOwn == ~ALLOW_OLD_NO_LINEAGE /\ (NewestOwn(t) \/ (~ALLOW_LINEAGE_NEEDS_NEWEST /\ t.lin # {}))
                              /\ t.conflict \in t.lin
                   w == IF conflictWins THEN t.conflict ELSE t.disk
                   l == IF conflictWins THEN t.disk ELSE t.conflict
                   r == MergeVersions(w, l, ALLOW_OLD_SUBSTRING_MERGE, ~ALLOW_BLANK_WINNER_BLOCK)
                   cleared == [t EXCEPT !.hasConf = FALSE, !.conflict = <<>>, !.confKind = "none"]
               IN IF dropOwn \/ t.conflict = t.disk \/ r.c = t.disk THEN s' = cleared
                  ELSE IF t.diskFull THEN s' = t        \* the merge cannot land: versions stay
                  ELSE s' = Hear([cleared EXCEPT
                         !.disk = r.c, !.fp = IF cleared.fp = "ok" THEN "stale" ELSE cleared.fp,
                         !.diskOwn = TRUE, !.hasPrev = cleared.hasPrev \/ cleared.diskOwn,
                         !.prev = IF cleared.diskOwn THEN cleared.disk ELSE cleared.prev,
                         !.lin = cleared.lin \cup {r.c}, !.linNew = r.c,
                         !.unseen = TRUE, !.reconDue = TRUE, !.mtimeOld = FALSE,
                         !.spurious = cleared.spurious \/ r.sp])

\* Other writers and the file system -----------------------------------------------------

ExternalEdit ==
  /\ ALLOW_EXTERNAL_EDIT /\ s.loc = {"active"}
  /\ \E x \in ExtEdits \ s.used :
       s' = [s EXCEPT !.disk = Append(s.disk, x), !.typed = s.typed \cup {x}, !.used = s.used \cup {x},
                      !.fp = IF s.fp = "ok" THEN "stale" ELSE s.fp,
                      !.diskOwn = FALSE, !.unseen = TRUE, !.mtimeOld = FALSE]

\* Obsidian rewrites the properties (or the other Mac moves the file): same text, new bytes.
ExternalMetaWrite ==
  /\ ALLOW_META_WRITE /\ s.loc = {"active"} /\ s.fp = "ok"
  /\ s' = [s EXCEPT !.fp = "stale", !.unseen = TRUE]

\* Obsidian (open on the note, or a plugin) writes back an older copy of our text.
ObsidianStaleRewrite ==
  /\ ALLOW_OBSIDIAN_STALE_REWRITE /\ s.loc = {"active"} /\ s.hasPrev /\ s.prev # s.disk
  /\ s' = [s EXCEPT !.disk = s.prev, !.diskOwn = FALSE, !.unseen = TRUE, !.mtimeOld = FALSE,
                    !.fp = IF s.fp = "ok" THEN "stale" ELSE s.fp,
                    !.extRemoved = s.extRemoved \cup (Toks(s.disk) \ Toks(s.prev))]

\* The other Mac, offline, edited an older copy: iCloud keeps one version as the file
\* and the other as an unresolved conflict version.
ExternalConflict ==
  /\ ALLOW_OTHER_MAC_CONFLICT /\ s.loc = {"active"} /\ ~s.hasConf
  /\ \E x \in ExtEdits \ s.used, useOld \in BOOLEAN :
       /\ (useOld => s.hasPrev)
       /\ s' = [s EXCEPT !.conflict = Append(IF useOld THEN s.prev ELSE s.disk, x),
                         !.typed = s.typed \cup {x}, !.used = s.used \cup {x},
                         !.hasConf = TRUE, !.confKind = "ext",
                         !.unseen = TRUE]

\* Hypothesis H1: iCloud keeps an older write of THIS Mac as a conflict version.
ICloudSelfConflict ==
  /\ ALLOW_ICLOUD_SELF_CONFLICT /\ s.loc = {"active"} /\ ~s.hasConf
  /\ s.hasPrev /\ s.prev # s.disk
  /\ s' = [s EXCEPT !.hasConf = TRUE, !.conflict = s.prev, !.confKind = "self", !.unseen = TRUE]

\* The other Mac (or an agent) archives, trashes or deletes the file.
ExternalMove ==
  /\ ALLOW_EXTERNAL_MOVE /\ s.loc = {"active"}
  /\ \E to \in {"archive", "trash", "none"} :
       s' = [s EXCEPT !.loc = IF to = "none" THEN {} ELSE {to},
                      !.trashAge = "fresh", !.trashWriteAge = "none", !.mtimeOld = FALSE,
                      !.extRemoved = IF to = "none" THEN s.extRemoved \cup Toks(s.disk) ELSE s.extRemoved,
                      !.unseen = TRUE, !.reconDue = TRUE]

FileVanishes == /\ ALLOW_UNLISTED /\ s.app = "running" /\ s.listed /\ s.loc # {} /\ s.flaky > 0
                /\ s' = [s EXCEPT !.flaky = s.flaky - 1, !.listed = FALSE, !.unseen = TRUE, !.reconDue = TRUE]
FileReturns  == /\ ~s.listed /\ s.app = "running"
                /\ s' = [s EXCEPT !.listed = TRUE, !.unseen = TRUE, !.reconDue = TRUE]

PlaceholderAppears == /\ ALLOW_PLACEHOLDER /\ ~s.ph /\ s.flaky > 0 /\ s' = [s EXCEPT !.flaky = s.flaky - 1, !.ph = TRUE, !.unseen = TRUE, !.reconDue = TRUE]
PlaceholderGoes == /\ s.ph /\ s' = [s EXCEPT !.ph = FALSE, !.unseen = TRUE, !.reconDue = TRUE]

DiskFills == /\ ALLOW_WRITE_FAILURE /\ ~s.diskFull /\ s.flaky > 0 /\ s' = [s EXCEPT !.flaky = s.flaky - 1, !.diskFull = TRUE]
DiskFrees == /\ s.diskFull /\ s' = [s EXCEPT !.diskFull = FALSE]

Next ==
  \/ Type \/ EraseAll \/ ClickIntoText \/ GrabTitleBar \/ SwitchAway \/ SaveFires
  \/ CloseNote \/ PanelArchive \/ Quit \/ Relaunch \/ Restore \/ DeleteForever
  \/ RestoreFromTrash \/ MonthPasses
  \/ WindowHears \/ Reconcile \/ ConflictSweep
  \/ ExternalEdit \/ ExternalMetaWrite \/ ObsidianStaleRewrite \/ ExternalConflict
  \/ ICloudSelfConflict \/ ExternalMove \/ FileVanishes \/ FileReturns
  \/ DiskFills \/ DiskFrees \/ PlaceholderAppears \/ PlaceholderGoes

\* With lifecycle steps off, Quit is the end of the story; a finished window too.
Done == (s.app = "quit" \/ s.win = "closed") /\ ~ALLOW_LIFECYCLE /\ UNCHANGED vars

Spec == Init /\ [][Next \/ Done]_vars

\* Liveness runs: the environment and the app eventually do what they can. Failures are
\* finite: `flaky` bounds how many times the disk, the listing or iCloud misbehave.
Fairness == /\ WF_vars(Reconcile) /\ WF_vars(WindowHears) /\ WF_vars(SaveFires)
            /\ WF_vars(DiskFrees) /\ WF_vars(FileReturns) /\ WF_vars(PlaceholderGoes)
LiveSpec == Spec /\ Fairness

-----------------------------------------------------------------------------
\* Rules

TypeOK ==
  /\ s.app \in {"running", "quit"} /\ s.win \in {"open", "closed"}
  /\ s.loc \subseteq Folders /\ s.fp \in {"ok", "stale", "none"}
  /\ s.focus \in {"typing", "titlebar", "away"}
  /\ Toks(s.disk) \subseteq (Real \cup {"D"}) /\ Toks(s.buf) \subseteq (Real \cup {"D"})

\* Text the person or an outside writer put in the note is still somewhere: the
\* window, a held-back edit, the file (wherever it is), a conflict version, a
\* recovered copy, or a recovery file; unless the outside writer removed it itself,
\* or the trash purged it after 30 days.
KeptOf(t) ==
  (IF t.app = "running" /\ t.win = "open" THEN Toks(t.buf) \cup (IF t.hasPend THEN Toks(t.pend) ELSE {}) ELSE {})
  \cup (IF t.loc # {} THEN Toks(t.disk) \cup (IF t.hasConf THEN Toks(t.conflict) ELSE {}) ELSE {})
  \cup Toks(t.rec) \cup t.recDir

TextKept(t) == t.legitGone \/ (t.typed \subseteq (KeptOf(t) \cup t.extRemoved))
TypedTextKept == TextKept(s)

\* A "Conflicted copy" block appears only when both sides hold text the other lacks.
NoSpuriousConflictBlock == ~s.spurious

\* A merge never leaves a line of the text outside the blocks twice.
NoRepeatedText == NoRepeat(s.disk) /\ (s.win = "closed" \/ NoRepeat(s.buf))

OneLifecycleState == Cardinality(s.loc) <= 1

PurgeRespectsRetention == ~s.purgedEarly

\* When nothing is in flight and the person is not in the window, the window shows
\* what is on disk and holds no deferred edit.
Settled ==
  /\ s.app = "running" /\ s.win = "open" /\ s.loc = {"active"} /\ s.listed
  /\ ~s.armed /\ ~s.unseen /\ ~s.hasConf /\ s.focus = "away" /\ ~s.reconDue
WindowMatchesDisk == Settled => (s.buf = s.disk /\ ~s.hasPend)

\* A window is never closed for a note that is still in the active folder.
NoFalseClose == ~s.falseClose

\* An untouched new note leaves no file.
NoUntouchedBlankFile == ~s.blankUntouched

\* The window can always be closed with its text kept (a recovery file counts), whenever
\* writes work. Checked as: a close step exists that ends with the window closed and
\* every typed line still somewhere.
CloseAlwaysWorks ==
  (WinOpen /\ ~s.diskFull /\ MayWrite) =>
    (LET r == PersonClose(s) IN r.closed /\ TextKept(r.st))

\* A note that is gone from the active folder, with its window open, is closed
\* once the file system answers and writes succeed again.
GoneOpen == s.app = "running" /\ s.win = "open" /\ s.hasFile /\ s.loc # {"active"}
            /\ s.listed /\ ~s.diskFull /\ ~s.ph
GoneWindowCloses == []((GoneOpen /\ s.hasFile) => <>(s.win = "closed" \/ s.loc = {"active"} \/ s.app = "quit"))

=============================================================================
