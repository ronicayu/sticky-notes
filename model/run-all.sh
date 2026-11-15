#!/bin/bash
# Reruns every config of both models into a new folder, then checks that every regress config
# holds when its ALLOW_OLD_* switches are set back to FALSE (the "base holds" claim).
# usage: ./run-all.sh NEW_OUT_DIR      (the folder must not exist yet)
set -e
cd "$(dirname "$0")"
out=${1:?usage: run-all.sh NEW_OUT_DIR}
R=/Users/ronica/.claude/plugins/cache/ronica-skills/statechart/0.3.0/skills/statechart/scripts/statechart
export TLA2TOOLS=$HOME/.cache/statechart/tla2tools.jar JAVA=/opt/homebrew/opt/openjdk/bin/java
mkdir "$out"
for f in n-*.cfg; do $R NoteDocument.tla --config "$f" --view note-doc-view.mjs --out "$out/${f%.cfg}" > /dev/null; done
for f in d-*.cfg; do $R DailyDocument.tla --config "$f" --view daily-doc-view.mjs --out "$out/${f%.cfg}" > /dev/null; done
for f in n-*.cfg d-*.cfg; do
  grep -q "^  ALLOW_OLD_.* = TRUE" "$f" || continue
  spec=NoteDocument.tla; case "$f" in d-*) spec=DailyDocument.tla;; esac
  base=/tmp/statechart-base-check; mkdir -p "$base"; cp "$spec" LineMerge.tla "$base/"
  sed -E 's/^(  ALLOW_OLD_[A-Z_]+) = TRUE/\1 = FALSE/' "$f" > "$base/$f"
  (cd "$base" && "$JAVA" -XX:+UseParallelGC -cp "$TLA2TOOLS" tlc2.TLC -workers 4 -config "$f" "$spec" 2>&1 \
     | grep -qE "No error has been found") && echo "base holds: $f" || echo "BASE BREAKS: $f"
done
echo "Read $out/*/report.md; rules that break are listed under '## <Rule> breaks'."
