#!/usr/bin/env bash
# Tests for hooks/ against real temp git repos and a stubbed herdr (no running server).
# Run: test/hooks.test.sh            (uses `bash` on PATH)
#      BASH_BIN=/bin/bash test/hooks.test.sh   (macOS bash 3.2)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASH_BIN="${BASH_BIN:-bash}"
TMP="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

# herdr stub: logs every call; `pane list` returns one pane.
mkdir -p "$TMP/bin"
cat >"$TMP/bin/herdr" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$HERDR_LOG"
[ "$1 $2" = "pane list" ] && echo '{"result":{"panes":[{"pane_id":"w1:p1"}]}}'
exit 0
EOF
chmod +x "$TMP/bin/herdr"
export HERDR_BIN_PATH="$TMP/bin/herdr" HERDR_LOG="$TMP/herdr.log"
export HERDR_PLUGIN_CONFIG_DIR="$TMP/plugin-config"
unset HERDR_PANE_ID

pass=0
fail=0
check() { # check <name> <command...>
  local name="$1"; shift
  if "$@"; then printf 'ok - %s\n' "$name"; pass=$((pass + 1))
  else printf 'not ok - %s\n' "$name" >&2; cat "$TMP/out" >&2 || true; fail=$((fail + 1)); fi
}

g() { git -c user.email=t@t -c user.name=t "$@"; }

# Fresh primary checkout with an "origin" so upstream checks work.
new_repo() {
  rm -rf "$TMP/repo" "$TMP/origin.git" "$TMP/wt"
  git init -q --bare "$TMP/origin.git"
  git init -q -b main "$TMP/repo"
  printf '.env\n.env.*\nnode_modules/\n' >"$TMP/repo/.gitignore"
  g -C "$TMP/repo" add .gitignore && g -C "$TMP/repo" commit -q -m init
  g -C "$TMP/repo" remote add origin "$TMP/origin.git"
  g -C "$TMP/repo" push -q -u origin main
}

# event <created|removed> <branch> [linked]
event() {
  jq -n --arg wt "$TMP/wt" --arg root "$TMP/repo" --arg b "$2" --argjson linked "${3:-true}" '{
    event: "worktree_\($ARGS.positional[0])",
    data: {
      workspace_id: "w1",
      workspace: { workspace_id: "w1", label: "my feature",
        worktree: { repo_root: $root, repo_name: "repo", is_linked_worktree: $linked } },
      worktree: { path: $wt, branch: $b, is_detached: false, is_linked_worktree: $linked }
    }}' --args "$1"
}

hook() { # hook <created|removed> <branch> [linked]
  : >"$HERDR_LOG"
  HERDR_PLUGIN_EVENT_JSON="$(event "$@")" "$BASH_BIN" "$ROOT/hooks/on-$1.sh" >"$TMP/out" 2>&1
}

config() { mkdir -p "$TMP/repo/.herdr" && printf '%s' "$1" >"$TMP/repo/.herdr/lifecycle.json"; }

# ---- created ------------------------------------------------------------------
new_repo
g -C "$TMP/repo" worktree add -q "$TMP/wt" -b feat
echo SECRET=1 >"$TMP/repo/.env"
echo X=1 >"$TMP/repo/.env.local"
echo T=1 >"$TMP/repo/.env.example"

check "repo without config is ignored" hook created feat
check "  ...and nothing was copied or run" test ! -e "$TMP/wt/.env" -a ! -s "$HERDR_LOG"

config '{"copy": [".env", ".env.*"], "setup": "echo \"$HERDR_LIFECYCLE_LABEL\" > label.txt"}'
check "created hook succeeds" hook created feat
check "copies matching gitignored files" cmp -s "$TMP/repo/.env" "$TMP/wt/.env"
check "copies glob matches" test -f "$TMP/wt/.env.local"
check "never copies *.example" test ! -e "$TMP/wt/.env.example"
check "runs setup in the first pane" grep -q '^pane run w1:p1 cd ' "$HERDR_LOG"

# The pane command must work when actually run by a shell.
cmd="$(sed -n 's/^pane run w1:p1 //p' "$HERDR_LOG")"
(cd / && eval "$cmd")
check "setup runs in the worktree with HERDR_LIFECYCLE_* env" grep -qx "my feature" "$TMP/wt/label.txt"

echo CHANGED=1 >"$TMP/wt/.env"
hook created feat
check "does not overwrite existing files" grep -q CHANGED "$TMP/wt/.env"

check "primary checkout (not linked) is ignored" hook created feat false
check "  ...and nothing was run" test ! -s "$HERDR_LOG"

rm "$TMP/repo/.herdr/lifecycle.json"
mkdir -p "$HERDR_PLUGIN_CONFIG_DIR/repos"
echo '{"setup": "true"}' >"$HERDR_PLUGIN_CONFIG_DIR/repos/repo.json"
hook created feat
check "falls back to plugin config dir repos/<name>.json" grep -q '^pane run' "$HERDR_LOG"
rm -rf "$HERDR_PLUGIN_CONFIG_DIR"

# ---- removed: branch cleanup -------------------------------------------------
removed_case() { # removed_case <name> <expect-branch: kept|deleted> <setup-fn>
  new_repo
  g -C "$TMP/repo" worktree add -q "$TMP/wt" -b feat
  config '{"teardown": "echo \"$HERDR_LIFECYCLE_WORKTREE|$HERDR_LIFECYCLE_BRANCH|$PWD\" > teardown.txt"}'
  "$3"
  rm -rf "$TMP/wt" # herdr deletes the checkout before firing the event
  hook removed feat || true
  if [ "$2" = deleted ]; then
    check "$1" bash -c "! git -C '$TMP/repo' show-ref --quiet refs/heads/feat"
  else
    check "$1" git -C "$TMP/repo" show-ref --quiet refs/heads/feat
  fi
}
merged() { :; }
unpushed() { g -C "$TMP/wt" commit -q --allow-empty -m wip; }
pushed() { unpushed && g -C "$TMP/wt" push -q -u origin feat; }

removed_case "deletes a merged branch" deleted merged
check "teardown runs from the primary checkout with the old path" \
  grep -qx "$TMP/wt|feat|$TMP/repo" "$TMP/repo/teardown.txt"
check "prunes the stale worktree entry" bash -c "! git -C '$TMP/repo' worktree list | grep -q '$TMP/wt'"
removed_case "deletes a branch whose commits are all pushed" deleted pushed
removed_case "keeps a branch with unpushed commits" kept unpushed

no_delete() { config '{"deleteBranch": false}'; }
removed_case "deleteBranch: false keeps the branch" kept no_delete

protect() { config '{"protectedBranches": ["feat"]}'; }
removed_case "keeps protectedBranches" kept protect

failing() { config '{"teardown": "exit 3"}'; }
removed_case "failed teardown keeps the branch" kept failing
check "  ...and notifies" grep -q '^notification show Worktree teardown failed' "$HERDR_LOG"

new_repo
config '{}'
hook removed main || true
check "  ...output says protected" grep -q "kept branch main: protected" "$TMP/out"
check "never deletes main" git -C "$TMP/repo" show-ref --quiet refs/heads/main

printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
