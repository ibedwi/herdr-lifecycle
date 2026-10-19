# hooks/lib.sh — shared by the event hooks. Source, don't run.
#
# Parses $HERDR_PLUGIN_EVENT_JSON into EV_* vars and finds the repo's lifecycle config.
# Plugins are global, so a repo without a config is ignored: every hook starts with
#   load_event && load_config || exit 0

HERDR="${HERDR_BIN_PATH:-herdr}"

# EV_WORKTREE  checkout path (gone already on worktree.removed)
# EV_BRANCH    branch name, empty when detached
# EV_LINKED    "true" for a linked worktree, never the primary checkout
# EV_REPO_ROOT primary checkout of the repo
# EV_REPO_NAME basename herdr shows for the repo
# EV_WS / EV_LABEL  herdr workspace id and label
load_event() {
  local ev="${HERDR_PLUGIN_EVENT_JSON:?}"
  EV_WORKTREE="$(jq -r '.data.worktree.path // empty' <<<"$ev")"
  EV_BRANCH="$(jq -r 'if .data.worktree.is_detached then empty else .data.worktree.branch // empty end' <<<"$ev")"
  EV_LINKED="$(jq -r '.data.worktree.is_linked_worktree // false' <<<"$ev")"
  EV_REPO_ROOT="$(jq -r '.data.workspace.worktree.repo_root // empty' <<<"$ev")"
  EV_REPO_NAME="$(jq -r '.data.workspace.worktree.repo_name // empty' <<<"$ev")"
  EV_WS="$(jq -r '.data.workspace.workspace_id // .data.workspace_id // empty' <<<"$ev")"
  EV_LABEL="$(jq -r '.data.workspace.label // empty' <<<"$ev")"
  [ "$EV_LINKED" = "true" ] && [ -n "$EV_WORKTREE" ] && [ -n "$EV_REPO_ROOT" ]
}

# CONFIG = first of <repo>/.herdr/lifecycle.json, then
# <plugin config dir>/repos/<repo name>.json (for repos you don't want to commit it to).
load_config() {
  local c
  for c in "$EV_REPO_ROOT/.herdr/lifecycle.json" \
    "${HERDR_PLUGIN_CONFIG_DIR:-/nonexistent}/repos/${EV_REPO_NAME:-$(basename "$EV_REPO_ROOT")}.json"; do
    [ -f "$c" ] && { CONFIG="$c"; return 0; }
  done
  return 1
}

cfg() { jq -r "$1" "$CONFIG"; }

# Env every repo command gets, as KEY=VALUE words for `env`.
lifecycle_env() {
  printf '%s\n' \
    "HERDR_LIFECYCLE_WORKTREE=$EV_WORKTREE" \
    "HERDR_LIFECYCLE_BRANCH=$EV_BRANCH" \
    "HERDR_LIFECYCLE_REPO_ROOT=$EV_REPO_ROOT" \
    "HERDR_LIFECYCLE_LABEL=$EV_LABEL" \
    "HERDR_LIFECYCLE_WORKSPACE_ID=$EV_WS"
}

notify() {
  "$HERDR" notification show "$1" --body "$2" >/dev/null 2>&1 || true
}
