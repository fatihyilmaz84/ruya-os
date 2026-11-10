#!/bin/bash
# Lists every test that exists at BASE but no longer at HEAD (a deleted or renamed test), so a
# review sees it without counting by hand (T-147 round 1 lost nine Home tests silently, lead-9).
# Qt Quick tests: `function test_*` in shell/tests/*.qml, keyed by file. Rust: the name of each
# function after a #[test] or #[tokio::test] line, keyed by file.
# Usage: scripts/lost-tests.sh [BASE] [HEAD]   (default: the merge base with main, and HEAD)
# Exit 0: nothing lost. Exit 1: the lost tests are printed; a rename or a deliberate removal must
# then be named in the task's Outcome (root CLAUDE.md: no test is deleted to get green).
set -euo pipefail
head_ref="${2:-HEAD}"
base_ref="${1:-$(git merge-base main "$head_ref")}"

list() {   # list REF -> "file:test" lines
  local ref="$1"
  git ls-tree -r --name-only "$ref" -- shell/tests services | grep -E '(\.qml|\.rs)$' | while read -r f; do
    case "$f" in
      *.qml)
        git show "$ref:$f" | grep -oE 'function test_[A-Za-z0-9_]+' | sed "s|^function |$f:|" ;;
      *.rs)
        git show "$ref:$f" | awk -v f="$f" '
          /#\[(tokio::)?test/ { want = 1; next }
          want && /fn [A-Za-z0-9_]+/ { match($0, /fn [A-Za-z0-9_]+/); print f ":" substr($0, RSTART + 3, RLENGTH - 3); want = 0 }' ;;
    esac
  done | sort -u
}

lost=$(comm -23 <(list "$base_ref") <(list "$head_ref"))
if [ -z "$lost" ]; then
  echo "lost-tests: none ($base_ref..$head_ref)"
  exit 0
fi
echo "lost-tests: $(printf '%s\n' "$lost" | wc -l) test(s) at $base_ref are gone at $head_ref:"
printf '  %s\n' $lost
exit 1
