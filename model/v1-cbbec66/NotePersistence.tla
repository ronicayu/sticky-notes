--------------------------- MODULE NotePersistence ---------------------------
\* Model (a): one sticky note's persistence in Obsidian vault mode, with the
\* vault inside iCloud Drive (the owner's set-up).
\* Code modelled at commit cbbec6621a3c81c6a5cd2bfa53618237bd35e156 (branch
\* masterpiece-plan). NOTES.md maps every action to file:line.
\*
\* Text abstraction. A body is a SET of edit tokens:
\*   "c"         text the note was created with (clipboard / Service capture)
\*   "l1", "l2"  text typed in this app, in that order
\*   "x1"        text written by another writer (Obsidian, the other Mac)
\*   "D"         a "Conflicted copy" block appended by ConflictResolver
\* `rewrites` holds the tokens that were NOT pure appends (a backspace or a
\* mid-line insert). A newer version N contains an older version O as a
\* substring exactly when O \subseteq N and every token N added since O was an
\* append. That is the `contains` test ConflictResolver.merge relies on.
\* The Markdown round trip (renderMarkdown -> read) returns the body
\* unchanged (checked by reading MarkdownFile.parse/serialize), so a body
\* read back from our own write equals what we wrote.
\*
\* All state is one record `s`, so every action names only what it changes.

EXTENDS FiniteSets, Naturals

CONSTANTS
  PREFILLED,                        \* the note starts with captured text "c"
  \* --- environment actors (TRUE = can happen) ---
  ALLOW_ICLOUD_SELF_CONFLICT,       \* H1: iCloud keeps an older write of THIS Mac as a conflict version
  ALLOW_OBSIDIAN_STALE_REWRITE,     \* Obsidian / a plugin rewrites the file from an older copy of our text
  ALLOW_OTHER_MAC_CONFLICT,         \* the other Mac edits an older copy: genuine conflict version
  ALLOW_EXTERNAL_EDIT,              \* Obsidian / the other Mac edits the current file
  ALLOW_EXTERNAL_ARCHIVE,           \* the other Mac archives the note
  ALLOW_OTHER_MAC_DISCARDS_EMPTY,   \* the other Mac's window, still empty, discards the note (R10)
  ALLOW_WRITE_FAILURE,              \* a write fails twice (disk full, permission) (R2)
  ALLOW_TRANSIENT_UNLISTED,         \* the file is briefly unreadable / missing from the listing (R3)
  ALLOW_PANEL,                      \* the notes panel's archive (Cmd-Backspace) is used (R9)
  ALLOW_LIFECYCLE,                  \* archive / trash / purge / relaunch steps
  PROMPT_WATCHER,                   \* assume the watcher delivers an outside change before the app writes
                                    \* (closes the blind-write window; used by regress configs only)
  \* --- open defects in the current code (TRUE = the code as it is) ---
  ALLOW_BLIND_WRITE,                \* a save does not re-read a change the watcher has not delivered (R1)
  ALLOW_STALE_PERSISTED_MARK,       \* applying an external version leaves lastPersistedContent stale
  ALLOW_PERSIST_MARK_BEFORE_WRITE,  \* persist() records lastPersisted even when the save did not land (R2)
  ALLOW_EMPTY_DISCARD_IGNORES_DISK, \* "empty" is judged from the window only, not from the file
  ALLOW_HARD_DELETE_ON_DISCARD,     \* discardActive unlinks the file instead of moving it to .trash (R10)
  ALLOW_DROP_ON_EXTERNAL_REMOVE,    \* reconcile closes the window and drops unsaved typing (R3, R9, R10)
  ALLOW_PANEL_ARCHIVE_NO_FLUSH,     \* the panel archives without flushing the open window (R9)
  ALLOW_SAVE_DROPPED_WHEN_GONE,     \* a save to a note no longer in the active folder is silently skipped (R2, R9)
  ALLOW_ONE_SIDED_BLOCK,     \* Note.merge appends a version that is our own older text or contains the winner
  \* --- bugs already fixed (TRUE = bring the old behaviour back) ---
  ALLOW_OLD_NO_QUIT_FLUSH,          \* 0.1
  ALLOW_OLD_PURGE_BY_MTIME,         \* 0.2
  ALLOW_OLD_ARCHIVE_NO_FLUSH,       \* 0.3
  ALLOW_OLD_SAVE_NO_MERGE,          \* 0.4
  ALLOW_OLD_NO_ECHO_FILTER,         \* R1 of BUGFIX-PLAN round 2
  ALLOW_OLD_CLOSE_NO_MERGE,         \* R3 of BUGFIX-PLAN round 2
  ALLOW_OLD_APPLY_WHEN_NOT_EDITING  \* 6cbd1f0

LocalEdits == {"l1", "l2"}
ExtEdits   == {"x1"}
Real       == {"c"} \cup LocalEdits \cup ExtEdits
Tokens     == Real \cup {"D"}
Folders    == {"active", "archive", "trash"}
Init0      == IF PREFILLED THEN {"c"} ELSE {}

VARIABLE s
vars == <<s>>

\* AppDelegate.makeNote: the store writes the new note directly (not via
\* persist()), so lastPersistedContent is nil, and the watcher will echo it.
Init == s = [
  app |-> "running", win |-> "open", loc |-> {"active"}, listed |-> TRUE,
  disk |-> Init0, diskOwn |-> TRUE, buf |-> Init0,
  hasPersisted |-> FALSE, persisted |-> {},
  armed |-> FALSE, hasPending |-> FALSE, pending |-> {},
  unseen |-> TRUE, focus |-> "typing", touched |-> FALSE,
  typed |-> Init0, rewrites |-> {}, extRemoved |-> {},
  hasConflict |-> FALSE, conflict |-> {}, conflictKind |-> "none",
  hasPrevOwn |-> FALSE, prevOwn |-> {},
  spurious |-> FALSE, purgedEarly |-> FALSE, legitGone |-> FALSE,
  trashAge |-> "fresh", mtimeOld |-> FALSE ]

-----------------------------------------------------------------------------
\* Text helpers

Contains(newer, older) == older \subseteq newer /\ (newer \ older) \cap s.rewrites = {}

\* Both sides hold real text the other lacks: a genuine two-writer conflict.
Genuine(a, b) == ((a \ b) \cap Real # {}) /\ ((b \ a) \cap Real # {})

\* ConflictResolver.merge with two versions, `w` the winner (newest
\* updatedAt). The loser is appended under a divider unless it is empty,
\* equal, or a substring of the winner (ConflictResolver.swift:15-40).
\* With ALLOW_ONE_SIDED_BLOCK = FALSE (proposed fix): a loser that
\* contains the winner replaces it, and a loser with nothing the winner lacks
\* is dropped; only a genuine divergence gets a divider.
MergeRes(w, l) ==
  IF (l \cap Real = {}) \/ l = w \/ Contains(w, l)
    THEN [c |-> w, sp |-> FALSE]
  ELSE IF ~ALLOW_ONE_SIDED_BLOCK /\ ~Genuine(w, l)
    THEN [c |-> w \cup l, sp |-> FALSE]
  ELSE [c |-> w \cup l \cup {"D"}, sp |-> ~Genuine(w, l)]

\* mergePendingExternalNote: the buffer gets updatedAt = now, so it wins.
CtlMerge == IF ~s.hasPending \/ s.pending = s.buf THEN [c |-> s.buf, sp |-> FALSE]
            ELSE MergeRes(s.buf, s.pending)

PendC == IF s.hasPending THEN s.pending ELSE {}

\* NoteStore.save: atomic replace of the active file; skipped when the note
\* is no longer active (no-resurrect guard). With ALLOW_BLIND_WRITE = FALSE
\* (proposed fix) the save re-reads the file and folds in an unseen change.
Written(m) ==
  IF ~ALLOW_BLIND_WRITE /\ (~s.hasPersisted \/ s.disk # s.persisted) /\ ~(s.disk \subseteq m)
    THEN MergeRes(m, s.disk)
    ELSE [c |-> m, sp |-> FALSE]

\* The state after this app writes body m (ok = the write landed).
AfterWrite(t, m, ok) ==
  IF "active" \in t.loc /\ ok
    THEN [t EXCEPT !.disk = Written(m).c, !.diskOwn = TRUE,
                   !.hasPrevOwn = (s.hasPrevOwn \/ s.diskOwn),
                   !.prevOwn = IF s.diskOwn THEN s.disk ELSE s.prevOwn,
                   !.unseen = TRUE, !.mtimeOld = FALSE,
                   !.spurious = (t.spurious \/ Written(m).sp)]
  ELSE IF ok /\ ~ALLOW_SAVE_DROPPED_WHEN_GONE
    THEN \* proposed fix: the text goes where the file went, or recreates it
         IF t.loc = {}
           THEN [t EXCEPT !.loc = {"active"}, !.disk = m, !.diskOwn = TRUE, !.unseen = TRUE]
           ELSE [t EXCEPT !.disk = t.disk \cup m, !.diskOwn = TRUE, !.unseen = TRUE]
    ELSE t

\* persist(): marks lastPersisted, then saves.
Persist(t, m, ok) ==
  LET marked == IF ok \/ ALLOW_PERSIST_MARK_BEFORE_WRITE \/ "active" \notin t.loc
                  THEN [t EXCEPT !.persisted = m, !.hasPersisted = TRUE] ELSE t
  IN AfterWrite(marked, m, ok)

Closed(t) == [t EXCEPT !.win = "closed", !.buf = {}, !.armed = FALSE,
                       !.hasPending = FALSE, !.pending = {}, !.hasPersisted = FALSE,
                       !.persisted = {}, !.focus = "away", !.touched = FALSE]

Opened(t) == [t EXCEPT !.win = "open", !.buf = t.disk, !.armed = FALSE,
                       !.hasPending = FALSE, !.pending = {}, !.hasPersisted = FALSE,
                       !.persisted = {}, !.focus = "away", !.touched = FALSE]

WriteOutcomes == IF ALLOW_WRITE_FAILURE THEN BOOLEAN ELSE {TRUE}

Running == s.app = "running"
WinOpen == Running /\ s.win = "open"

\* Guard on every step in which the app writes the note.
MayWrite == ~PROMPT_WATCHER \/ ~(s.unseen /\ ~s.diskOwn)

-----------------------------------------------------------------------------
\* The person, in the app

\* textDidChange -> scheduleSave
Type ==
  /\ WinOpen /\ s.focus = "typing"
  /\ \E e \in LocalEdits \ s.typed, rw \in BOOLEAN :
       /\ (e = "l1" \/ "l1" \in s.typed)
       /\ s' = [s EXCEPT !.buf = s.buf \cup {e}, !.typed = s.typed \cup {e},
                         !.rewrites = IF rw THEN s.rewrites \cup {e} ELSE s.rewrites,
                         !.armed = TRUE, !.touched = TRUE]

ClickIntoText ==
  /\ WinOpen /\ s.focus # "typing"
  /\ s' = [s EXCEPT !.focus = "typing"]

\* Clicking the note's own title bar drops first responder; the window stays key.
GrabTitleBar ==
  /\ WinOpen /\ s.focus = "typing"
  /\ s' = [s EXCEPT !.focus = "titlebar"]

DiscardLoc(l) == IF ALLOW_HARD_DELETE_ON_DISCARD \/ "active" \notin l
                   THEN l \ {"active"} ELSE (l \ {"active"}) \cup {"trash"}

Discard(t) == Closed([t EXCEPT !.loc = DiscardLoc(t.loc), !.trashAge = "fresh", !.unseen = TRUE,
                               !.mtimeOld = IF ALLOW_OLD_PURGE_BY_MTIME THEN t.mtimeOld ELSE FALSE])

DiscardAllowed ==
  ALLOW_EMPTY_DISCARD_IGNORES_DISK \/ (s.disk \cap Real = {} /\ ~s.hasPending /\ ~s.hasConflict)

\* windowDidResignKey
SwitchAway ==
  /\ MayWrite /\ WinOpen /\ s.focus # "away"
  /\ IF ~s.touched /\ s.buf \cap Real = {} /\ DiscardAllowed
       THEN \* isAbandonedCapture -> discardAbandonedCapture -> store.discardActive
            \* (with the proposed fix, a note whose file or deferred edit holds
            \* text is not abandoned, and falls through to the normal branch)
            s' = Discard(s)
     ELSE IF s.hasPending
       THEN \E ok \in WriteOutcomes :
              s' = Persist([s EXCEPT !.focus = "away", !.buf = CtlMerge.c,
                                     !.hasPending = FALSE, !.pending = {},
                                     !.spurious = s.spurious \/ CtlMerge.sp],
                           CtlMerge.c, ok)
       ELSE s' = [s EXCEPT !.focus = "away"]

\* The debounced save fires (scheduleSave work item).
SaveFires ==
  /\ MayWrite /\ WinOpen /\ s.armed
  /\ LET r == IF ALLOW_OLD_SAVE_NO_MERGE THEN [c |-> s.buf, sp |-> FALSE] ELSE CtlMerge
     IN \E ok \in WriteOutcomes :
          s' = Persist([s EXCEPT !.armed = FALSE, !.buf = r.c, !.hasPending = FALSE,
                                 !.pending = {}, !.spurious = s.spurious \/ r.sp],
                       r.c, ok)

\* closeNote: empty -> discardActive; otherwise persist, then archive.
CloseNote ==
  /\ MayWrite /\ WinOpen
  /\ IF s.buf \cap Real = {} /\ DiscardAllowed
       THEN s' = Discard(s)
       ELSE LET r == IF ALLOW_OLD_CLOSE_NO_MERGE \/ ALLOW_OLD_ARCHIVE_NO_FLUSH
                       THEN [c |-> s.buf, sp |-> FALSE] ELSE CtlMerge
                t1 == [s EXCEPT !.spurious = s.spurious \/ r.sp]
            IN \E ok \in WriteOutcomes :
                 LET t2 == IF ALLOW_OLD_ARCHIVE_NO_FLUSH THEN t1 ELSE Persist(t1, r.c, ok)
                 IN s' = Closed([t2 EXCEPT
                           !.loc = IF "active" \in t2.loc
                                     THEN (t2.loc \ {"active"}) \cup {"archive"} ELSE t2.loc,
                           !.unseen = TRUE])

\* applicationShouldTerminate -> flushPendingSaves; then the process exits.
Quit ==
  /\ MayWrite /\ Running
  /\ \E ok \in WriteOutcomes :
       LET t == IF s.win = "open" /\ s.armed /\ ~ALLOW_OLD_NO_QUIT_FLUSH
                  THEN Persist([s EXCEPT !.spurious = s.spurious \/ CtlMerge.sp], CtlMerge.c, ok)
                  ELSE s
       IN s' = Closed([t EXCEPT !.app = "quit", !.unseen = FALSE])

\* Launch: NoteStore.init purges expired trash; restoreActiveNotes opens the window.
Relaunch ==
  /\ ALLOW_LIFECYCLE /\ s.app = "quit"
  /\ LET due   == IF ALLOW_OLD_PURGE_BY_MTIME THEN s.mtimeOld ELSE s.trashAge = "old"
         purge == s.loc = {"trash"} /\ due
         t == [s EXCEPT !.app = "running", !.listed = TRUE,
                        !.loc = IF purge THEN {} ELSE s.loc,
                        !.purgedEarly = s.purgedEarly \/ (purge /\ s.trashAge = "fresh"),
                        !.legitGone = s.legitGone \/ (purge /\ s.trashAge = "old")]
     IN s' = IF t.loc = {"active"} THEN Opened(t) ELSE t

\* Notes panel / undo toast: archive -> active (reconcile then opens a window).
Restore ==
  /\ ALLOW_LIFECYCLE /\ Running /\ s.loc = {"archive"}
  /\ s' = [s EXCEPT !.loc = {"active"}, !.unseen = TRUE]

\* Notes panel "Delete permanently": archive -> .trash, deletion date stamped.
DeleteForever ==
  /\ ALLOW_LIFECYCLE /\ Running /\ s.loc = {"archive"}
  /\ s' = [s EXCEPT !.loc = {"trash"}, !.trashAge = "fresh",
                    !.mtimeOld = IF ALLOW_OLD_PURGE_BY_MTIME THEN s.mtimeOld ELSE FALSE]

RestoreFromTrash ==
  /\ ALLOW_LIFECYCLE /\ Running /\ s.loc = {"trash"}
  /\ s' = [s EXCEPT !.loc = {"archive"}, !.trashAge = "fresh"]

\* More than the 30-day retention passes.
MonthPasses ==
  /\ ALLOW_LIFECYCLE
  /\ (~s.mtimeOld \/ (s.loc = {"trash"} /\ s.trashAge = "fresh"))
  /\ s' = [s EXCEPT !.mtimeOld = TRUE,
                    !.trashAge = IF s.loc = {"trash"} THEN "old" ELSE s.trashAge]

\* Notes panel Cmd-Backspace: store.archive straight away (NotesPanelController.swift:385-388).
PanelArchive ==
  /\ MayWrite /\ ALLOW_PANEL /\ Running /\ s.loc = {"active"} /\ s.focus = "away"
  /\ IF ~ALLOW_PANEL_ARCHIVE_NO_FLUSH /\ s.win = "open"
       THEN \* proposed fix: route through the window's closeNote
            \E ok \in WriteOutcomes :
              LET t == Persist([s EXCEPT !.spurious = s.spurious \/ CtlMerge.sp], CtlMerge.c, ok)
              IN s' = Closed([t EXCEPT !.loc = {"archive"}, !.unseen = TRUE])
       ELSE s' = [s EXCEPT !.loc = {"archive"}, !.unseen = TRUE]

-----------------------------------------------------------------------------
\* The watcher delivers a file event (FileWatcher -> NoteStore.didChange):
\* NoteWindowController.handleStoreChange + AppDelegate.reconcileOpenWindows.

\* What the app does with the file as it now is (t.disk), once
\* NoteStore.didChange is posted. Does not touch t.unseen.
Deliver(t) ==
  CASE t.win = "open" /\ ~("active" \in t.loc /\ t.listed) ->
         \* reconcileOpenWindows -> closeAfterExternalDeletion
         IF ALLOW_DROP_ON_EXTERNAL_REMOVE \/ t.loc = {}
           THEN Closed(t)
           ELSE Closed([t EXCEPT !.disk = t.disk \cup t.buf \cup (IF t.hasPending THEN t.pending ELSE {})])
    [] t.win = "closed" /\ t.loc = {"active"} /\ t.listed ->
         Opened(t)            \* presentWindow(activate: false)
    [] t.win = "open" ->      \* handleStoreChange
         LET echo  == ~ALLOW_OLD_NO_ECHO_FILTER /\ t.hasPersisted /\ t.disk = t.persisted
             unsaved == t.armed \/ (t.hasPersisted /\ t.buf # t.persisted)
             defer == IF ALLOW_OLD_APPLY_WHEN_NOT_EDITING THEN t.focus = "typing"
                      ELSE unsaved \/ t.focus = "typing"
         IN IF echo \/ t.disk = t.buf THEN t
            ELSE IF defer THEN [t EXCEPT !.hasPending = TRUE, !.pending = t.disk]
            ELSE [t EXCEPT !.buf = t.disk,
                    !.persisted = IF ALLOW_STALE_PERSISTED_MARK THEN t.persisted ELSE t.disk,
                    !.hasPersisted = IF ALLOW_STALE_PERSISTED_MARK THEN t.hasPersisted ELSE TRUE]
    [] OTHER -> t

\* The watcher delivers a file event (FileWatcher -> NoteStore.didChange):
\* NoteWindowController.handleStoreChange + AppDelegate.reconcileOpenWindows.
WatcherDelivers ==
  /\ Running /\ s.unseen
  /\ s' = Deliver([s EXCEPT !.unseen = FALSE])

\* NoteStore.resolveConflictsIfDue -> resolveConflict (active + archive only).
\* It runs inside the watcher callback and posts didChange synchronously,
\* so the window sees the merged file in the same step; the merged write's
\* own file event follows later (unseen).
ConflictSweep ==
  /\ Running /\ s.hasConflict /\ s.loc \cap {"active", "archive"} # {}
  /\ \E conflictWins \in BOOLEAN :
       /\ (conflictWins => s.conflictKind = "ext")  \* an older own write is never the newest
       /\ LET w == IF conflictWins THEN s.conflict ELSE s.disk
              l == IF conflictWins THEN s.disk ELSE s.conflict
              r == MergeRes(w, l)
              t == [s EXCEPT !.hasConflict = FALSE, !.conflict = {}, !.conflictKind = "none"]
          IN s' = IF s.disk = s.conflict \/ r.c = s.disk THEN t
                  ELSE Deliver([t EXCEPT !.disk = r.c, !.diskOwn = TRUE,
                                 !.hasPrevOwn = s.hasPrevOwn \/ s.diskOwn,
                                 !.prevOwn = IF s.diskOwn THEN s.disk ELSE s.prevOwn,
                                 !.unseen = TRUE, !.mtimeOld = FALSE,
                                 !.spurious = s.spurious \/ r.sp])

-----------------------------------------------------------------------------
\* Other writers and the file system

ExternalEdit ==
  /\ ALLOW_EXTERNAL_EDIT /\ s.loc = {"active"}
  /\ \E x \in ExtEdits \ s.typed :   \* its shape only matters in conflict merges
       s' = [s EXCEPT !.disk = s.disk \cup {x}, !.typed = s.typed \cup {x},
                      !.diskOwn = FALSE, !.unseen = TRUE, !.mtimeOld = FALSE]

\* The other Mac edited an older copy before syncing: iCloud keeps one
\* version as the file and the other as an unresolved conflict version.
ExternalConflict ==
  /\ ALLOW_OTHER_MAC_CONFLICT /\ s.loc = {"active"} /\ ~s.hasConflict
  /\ \E x \in ExtEdits \ s.typed, rw \in BOOLEAN, useOld \in BOOLEAN :
       /\ (useOld => s.hasPrevOwn)
       /\ s' = [s EXCEPT !.conflict = (IF useOld THEN s.prevOwn ELSE s.disk) \cup {x},
                         !.typed = s.typed \cup {x},
                         !.rewrites = IF rw THEN s.rewrites \cup {x} ELSE s.rewrites,
                         !.hasConflict = TRUE, !.conflictKind = "ext", !.unseen = TRUE]

\* Hypothesis 1: the iCloud daemon keeps an OLDER write of this same Mac as
\* a conflict version (uncoordinated atomic saves every 0.5 s while the
\* previous upload is still in flight).
ICloudSelfConflict ==
  /\ ALLOW_ICLOUD_SELF_CONFLICT /\ s.loc = {"active"} /\ ~s.hasConflict
  /\ s.hasPrevOwn /\ s.prevOwn # s.disk
  /\ s' = [s EXCEPT !.hasConflict = TRUE, !.conflict = s.prevOwn,
                    !.conflictKind = "self", !.unseen = TRUE]

\* Obsidian (open on the same note, or a lint/format-on-save plugin) writes
\* the file back from its own copy, which still holds an older body we wrote.
\* Text it drops is the other writer's doing, not this app's: recorded in
\* extRemoved so the rule does not blame the app for it.
ObsidianStaleRewrite ==
  /\ ALLOW_OBSIDIAN_STALE_REWRITE /\ s.loc = {"active"}
  /\ s.hasPrevOwn /\ s.prevOwn # s.disk /\ s.prevOwn \subseteq s.disk
  /\ s' = [s EXCEPT !.disk = s.prevOwn, !.diskOwn = FALSE, !.unseen = TRUE,
                    !.mtimeOld = FALSE,
                    !.extRemoved = s.extRemoved \cup (s.disk \ s.prevOwn)]

ExternalArchive ==
  /\ ALLOW_EXTERNAL_ARCHIVE /\ s.loc = {"active"}
  /\ s' = [s EXCEPT !.loc = {"archive"}, !.unseen = TRUE]

\* R10: the other Mac still shows the note as empty (abandoned capture) and
\* discards it, deleting the file this Mac has typed into.
OtherMacDiscardsEmpty ==
  /\ ALLOW_OTHER_MAC_DISCARDS_EMPTY /\ ~PREFILLED /\ s.loc = {"active"}
  /\ s' = [s EXCEPT !.loc = DiscardLoc(s.loc), !.trashAge = "fresh", !.unseen = TRUE]

\* R3: the file is briefly unreadable or missing from the listing (mid-sync,
\* dataless), then comes back.
FileVanishes ==
  /\ ALLOW_TRANSIENT_UNLISTED /\ s.loc = {"active"} /\ s.listed
  /\ s' = [s EXCEPT !.listed = FALSE, !.unseen = TRUE]

FileReturns ==
  /\ ~s.listed
  /\ s' = [s EXCEPT !.listed = TRUE, !.unseen = TRUE]

Next ==
  \/ Type \/ ClickIntoText \/ GrabTitleBar \/ SwitchAway \/ SaveFires
  \/ CloseNote \/ Quit \/ Relaunch \/ Restore \/ DeleteForever
  \/ RestoreFromTrash \/ MonthPasses \/ PanelArchive
  \/ WatcherDelivers \/ ConflictSweep
  \/ ExternalEdit \/ ExternalConflict \/ ICloudSelfConflict
  \/ ObsidianStaleRewrite \/ ExternalArchive \/ OtherMacDiscardsEmpty
  \/ FileVanishes \/ FileReturns

\* With lifecycle steps off, Quit is the end of the story.
Done == s.app = "quit" /\ ~ALLOW_LIFECYCLE /\ UNCHANGED vars

Spec == Init /\ [][Next \/ Done]_vars

-----------------------------------------------------------------------------
\* Rules

TypeOK ==
  /\ s.app \in {"running", "quit"} /\ s.win \in {"open", "closed"}
  /\ s.loc \subseteq Folders
  /\ s.disk \subseteq Tokens /\ s.buf \subseteq Tokens /\ s.persisted \subseteq Tokens
  /\ s.pending \subseteq Tokens /\ s.conflict \subseteq Tokens /\ s.prevOwn \subseteq Tokens
  /\ s.focus \in {"typing", "titlebar", "away"}

\* No typed text is lost or silently overwritten: every token anyone typed is
\* still in the window, a deferred edit, the file, or a conflict version,
\* unless another writer removed it itself, or the note was purged from the
\* trash after retention.
Kept ==
  (IF s.app = "running" /\ s.win = "open" THEN s.buf \cup PendC ELSE {})
  \cup (IF s.loc # {} THEN s.disk \cup (IF s.hasConflict THEN s.conflict ELSE {}) ELSE {})

TypedTextKept == s.legitGone \/ (s.typed \subseteq (Kept \cup s.extRemoved))

\* A "Conflicted copy" block appears only when this app and another writer
\* each hold text the other lacks.
NoSpuriousConflictBlock == ~s.spurious

\* A note is never in two lifecycle states (folders) at once.
OneLifecycleState == Cardinality(s.loc) <= 1

\* Purge never removes a note deleted within retention.
PurgeRespectsRetention == ~s.purgedEarly

\* When nothing is in flight and the person is not in the window, the window
\* shows what is on disk and holds no deferred edit.
Settled ==
  /\ s.app = "running" /\ s.win = "open" /\ s.loc = {"active"} /\ s.listed
  /\ ~s.armed /\ ~s.unseen /\ ~s.hasConflict /\ s.focus = "away"
WindowMatchesDisk == Settled => (s.buf = s.disk /\ ~s.hasPending)

=============================================================================
