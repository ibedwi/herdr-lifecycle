#!/usr/bin/env bash
# worktree.removed -> run `teardown`, then drop the worktree's local git branch.
# Herdr fires this AFTER the checkout is deleted, so teardown runs from the primary
# checkout and gets the old path in $HERDR_LIFECYCLE_WORKTREE.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

load_event && load_config || exit 0
root="$EV_REPO_ROOT"

teardown="$(cfg '.teardown // empty')"
if [ -n "$teardown" ]; then
  if ! (cd "$root" && while IFS= read -r kv; do export "$kv"; done < <(lifecycle_env) \
    && bash -c "$teardown"); then
    notify "Worktree teardown failed" "${EV_LABEL:-$EV_WORKTREE}: see herdr plugin log list --plugin ${HERDR_PLUGIN_ID:-ibedwi.lifecycle}"
    echo "teardown failed; keeping branch $EV_BRANCH" >&2
    exit 1
  fi
fi

# Herdr removes the checkout but not its branch. Delete it only when no work can be lost:
# merged (git branch -d), or every commit is already on its upstream. Otherwise keep it.
git -C "$root" worktree prune
branch="$EV_BRANCH"
[ "$(cfg '.deleteBranch')" != "false" ] || exit 0  # not `// true`: jq's // swallows false
[ -n "$branch" ] && git -C "$root" show-ref --verify --quiet "refs/heads/$branch" || exit 0
default="$(git -C "$root" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"
if jq -e --arg b "$branch" --arg d "${default#origin/}" '
    ["main", "master", "develop", "development", "staging", "production", $d]
    + (.protectedBranches // []) | index($b)' "$CONFIG" >/dev/null; then
  echo "kept branch $branch: protected"
elif git -C "$root" worktree list --porcelain | grep -qx "branch refs/heads/$branch"; then
  echo "kept branch $branch: checked out in another worktree"
elif git -C "$root" branch -d "$branch" >/dev/null 2>&1; then
  echo "deleted branch $branch (merged)"
elif upstream="$(git -C "$root" rev-parse --abbrev-ref "$branch@{upstream}" 2>/dev/null)" \
  && [ -z "$(git -C "$root" rev-list "$upstream..$branch")" ]; then
  git -C "$root" branch -D "$branch" >/dev/null
  echo "deleted branch $branch (all commits on $upstream)"
else
  echo "kept branch $branch: has commits not on any upstream"
fi
