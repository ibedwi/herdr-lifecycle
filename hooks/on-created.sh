#!/usr/bin/env bash
# worktree.created -> bootstrap the new linked worktree from its primary checkout:
#   1. copy gitignored files matching `copy` (e.g. .env) that the fresh checkout lacks;
#   2. run `setup` in the workspace's first pane, so progress stays visible and is not
#      bound to this hook's lifetime.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

load_event && load_config || exit 0
[ -d "$EV_WORKTREE" ] || exit 0
repo="$EV_REPO_ROOT"
wt="$EV_WORKTREE"

# 1. Gitignored files. --directory collapses ignored dirs (node_modules etc.), so only
# top-level ignored entries are candidates. *.example files are never copied.
# (Plain while-read loops throughout: macOS /bin/bash is 3.2, no mapfile.)
patterns="$(cfg '.copy // [] | .[]')"
if [ -n "$patterns" ]; then
  while IFS= read -r f; do
    name="$(basename "$f")"
    case "$name" in *.example) continue ;; esac
    hit=0
    while IFS= read -r p; do
      # shellcheck disable=SC2254 # patterns are globs on purpose
      case "$name" in $p) hit=1 ;; esac
    done <<<"$patterns"
    [ "$hit" = 1 ] && [ -f "$repo/$f" ] && [ ! -e "$wt/$f" ] || continue
    mkdir -p "$wt/$(dirname "$f")"
    cp -p "$repo/$f" "$wt/$f"
    echo "copied $f"
  done < <(git -C "$repo" ls-files --others --ignored --exclude-standard --directory)
fi

# 2. Setup command, run by bash in the worktree's first pane.
setup="$(cfg '.setup // empty')"
[ -n "$setup" ] || exit 0
pane="${HERDR_PANE_ID:-}"
[ -n "$pane" ] || pane="$("$HERDR" pane list --workspace "$EV_WS" | jq -r '.result.panes[0].pane_id // empty')"
[ -n "$pane" ] || { echo "no pane for workspace $EV_WS; skipping setup" >&2; exit 1; }

cmd="cd $(printf '%q' "$wt") && env"
while IFS= read -r kv; do cmd+=" $(printf '%q' "$kv")"; done < <(lifecycle_env)
cmd+=" bash -c $(printf '%q' "$setup")"
"$HERDR" pane run "$pane" "$cmd" >/dev/null
echo "setup started in $pane for $wt"
