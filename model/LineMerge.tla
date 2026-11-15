------------------------------ MODULE LineMerge ------------------------------
\* Text operators shared by NoteDocument.tla and DailyDocument.tla.
\* A body is a SEQUENCE of line tokens (blank lines are not modelled; the code
\* compares non-empty lines too). "D" stands for a "Conflicted copy" divider
\* line. Each operator follows ConflictResolver.swift and
\* NoteDocument.mergedBody at commit c16cef1 (see NOTES.md).
EXTENDS Sequences, Naturals, FiniteSets

CONSTANT Outside   \* tokens written by another writer (Obsidian, the other Mac)

Toks(b)     == {b[i] : i \in 1..Len(b)}
Count(b, t) == Cardinality({i \in 1..Len(b) : b[i] = t})

\* ConflictResolver.isCovered: every line of `b` uses up one line of `base`.
\* (The "last line may be a prefix of a base line" rule is not modelled: the
\* model's lines are whole lines.)
Covered(b, base) == \A t \in Toks(b) : Count(b, t) <= Count(base, t)

\* ConflictResolver.isSuperset: `base` has text and its lines all appear in `b`
\* in the same order.
Superset(b, base) ==
  /\ base # <<>>
  /\ LET RECURSIVE Go(_, _)
         Go(k, n) == IF n > Len(b) THEN k
                     ELSE Go(IF k <= Len(base) /\ b[n] = base[k] THEN k + 1 ELSE k, n + 1)
     IN Go(1, 1) = Len(base) + 1

\* NoteDocument.mergedBody.appendedLines: `changed` is `base` plus lines at the end.
Appended(changed, base) ==
  /\ base # <<>>
  /\ Len(changed) > Len(base)
  /\ SubSeq(changed, 1, Len(base)) = base

TailOf(changed, base) == SubSeq(changed, Len(base) + 1, Len(changed))

\* String.contains for a sequence of lines.
HasRun(e, run) == \E i \in 0..(Len(e) - Len(run)) : SubSeq(e, i + 1, i + Len(run)) = run

\* A block under a divider is warranted when the two sides each hold text the other
\* lacks and at least one side's extra text comes from another writer. Two versions
\* of this person's own text (an older save against a newer one) are not.
Genuine(w, l) ==
  /\ (Toks(w) \ Toks(l)) # {} /\ (Toks(l) \ Toks(w)) # {}
  /\ ((Toks(w) \ Toks(l)) \cup (Toks(l) \ Toks(w))) \cap Outside # {}

\* ConflictResolver.mergeBodies(local, external): the local text keeps the top.
\* Result: c = merged body, blk = a divider block was appended, sp = it was spurious.
MergeBodies(l, e) ==
  IF e = <<>> \/ e = l THEN [c |-> l, blk |-> FALSE, sp |-> FALSE]
  ELSE IF l = <<>> THEN [c |-> e, blk |-> FALSE, sp |-> FALSE]
  ELSE IF Covered(e, l) THEN [c |-> l, blk |-> FALSE, sp |-> FALSE]
  ELSE IF Superset(e, l) THEN [c |-> e, blk |-> FALSE, sp |-> FALSE]
  ELSE [c |-> l \o <<"D">> \o e, blk |-> TRUE, sp |-> ~Genuine(l, e)]

\* ConflictResolver.merge with two versions; `w` has the newest date.
\* `substr` = the pre-b926059 rule: append unless the loser is already inside
\* the winner (no superset step).
\* `blankOk`: a blank winner is replaced by a loser that has text (the code does not).
MergeVersions(w, l, substr, blankOk) ==
  IF l = <<>> \/ l = w THEN [c |-> w, blk |-> FALSE, sp |-> FALSE]
  ELSE LET base == IF ~substr /\ ~Covered(l, w) /\ (Superset(l, w) \/ (blankOk /\ w = <<>>)) THEN l ELSE w
       IN IF Covered(l, base) THEN [c |-> base, blk |-> FALSE, sp |-> FALSE]
          ELSE [c |-> base \o <<"D">> \o l, blk |-> TRUE, sp |-> ~Genuine(base, l)]

\* NoteDocument.mergedBody: a three-way merge of one body against its base.
\* `loc` = what the person has, `ext` = the outside version, `base` = what the
\* document last wrote or read.
MergedBody(base, loc, ext) ==
  IF Appended(loc, base)
    THEN [c |-> IF HasRun(ext, TailOf(loc, base)) THEN ext ELSE ext \o TailOf(loc, base),
          blk |-> FALSE, sp |-> FALSE]
  ELSE IF Appended(ext, base)
    THEN [c |-> IF HasRun(loc, TailOf(ext, base)) THEN loc ELSE loc \o TailOf(ext, base),
          blk |-> FALSE, sp |-> FALSE]
  ELSE MergeBodies(loc, ext)

\* mergePendingExternal: each part is decided against the base.
ThreeWay(base, loc, ext) ==
  IF ext = base THEN [c |-> loc, blk |-> FALSE, sp |-> FALSE]
  ELSE IF loc = base THEN [c |-> ext, blk |-> FALSE, sp |-> FALSE]
  ELSE MergedBody(base, loc, ext)

\* Text before the first divider.
HeadText(b) == LET RECURSIVE H(_, _)
               H(i, acc) == IF i > Len(b) \/ b[i] = "D" THEN acc ELSE H(i + 1, Append(acc, b[i]))
           IN H(1, <<>>)

\* No line of the text outside blocks is there twice.
NoRepeat(b) == \A t \in Toks(HeadText(b)) : Count(HeadText(b), t) <= 1

=============================================================================
