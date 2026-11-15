#!/bin/bash
# Reruns every config of both models into a new folder (5 at a time), then checks that every
# regress config holds when its ALLOW_OLD_* switches are set back to FALSE (the "base holds" claim).
# usage: ./run-all.sh NEW_OUT_DIR      (the folder must not exist yet)
# The runner exits 1 when a rule breaks, which many configs are meant to show: its exit code is ignored.
cd "$(dirname "$0")"
out=${1:?usage: run-all.sh NEW_OUT_DIR}
export R=/Users/ronica/.claude/plugins/cache/ronica-skills/statechart/0.3.0/skills/statechart/scripts/statechart
export TLA2TOOLS=$HOME/.cache/statechart/tla2tools.jar JAVA=/opt/homebrew/opt/openjdk/bin/java
export out
mkdir "$out"
one() {  # one CONFIG-FILE: model check with the right spec and view
  f=$1; n=${f%.cfg}
  case "$f" in
    d-*|regress-daily-*) $R DailyDocument.tla --config "$f" --view daily-doc-view.mjs --out "$out/$n" > /dev/null 2>&1 || true ;;
    *) $R NoteDocument.tla --config "$f" --view note-doc-view.mjs --out "$out/$n" > /dev/null 2>&1 || true ;;
  esac
}
base() {  # base CONFIG-FILE: the same config with every ALLOW_OLD_* = FALSE must hold
  f=$1; spec=NoteDocument.tla; case "$f" in regress-daily-*) spec=DailyDocument.tla;; esac
  dir=/tmp/statechart-base-check/${f%.cfg}; mkdir -p "$dir"; cp "$spec" LineMerge.tla "$dir/"
  sed -E 's/^(  ALLOW_OLD_[A-Z_]+) = TRUE/\1 = FALSE/' "$f" > "$dir/$f"
  if (cd "$dir" && "$JAVA" -XX:+UseParallelGC -cp "$TLA2TOOLS" tlc2.TLC -workers 2 -config "$f" "$spec" 2>&1 \
        | grep -qE "No error has been found"); then echo "base holds: $f"; else echo "BASE BREAKS: $f"; fi
}
export -f one base
ls n-*.cfg d-*.cfg regress-*.cfg | xargs -P 5 -I{} bash -c 'one {}'
ls regress-*.cfg | xargs -P 5 -I{} bash -c 'base {}' | sort
echo "Read $out/*/report.md; a rule that breaks is listed under '## <Rule> breaks'."
