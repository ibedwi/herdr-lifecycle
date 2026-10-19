# herdr-lifecycle

A [herdr](https://herdr.dev) plugin that manages the lifecycle of worktree-backed
workspaces. It is a single global plugin, and each repo opts in with a small JSON file.

| herdr event | what happens |
|---|---|
| `worktree.created` | copy gitignored files (e.g. `.env`) from the primary checkout → run `setup` in the new workspace's first pane |
| `worktree.removed` | run `teardown` from the primary checkout → `git worktree prune` → delete the worktree's branch **only if no work can be lost** |

Repos without a config are ignored, and the primary checkout is never touched.

## Install

```bash
herdr plugin install ibedwi/herdr-lifecycle     # from GitHub
herdr plugin link /path/to/herdr-lifecycle      # or a local checkout, for development
```

Requires `bash`, `git`, `jq`. Works with macOS's bash 3.2.

## Configure a repo

Add `.herdr/lifecycle.json` to the repo's primary checkout (committed or not).
If you'd rather not keep it in the repo, put it at
`$(herdr plugin config-dir ibedwi.lifecycle)/repos/<repo-name>.json` instead.

```json
{
  "copy": [".env*"],
  "setup": "pnpm install",
  "teardown": "./scripts/teardown.sh --worktree \"$HERDR_LIFECYCLE_WORKTREE\"",
  "deleteBranch": true,
  "protectedBranches": ["staging"]
}
```

Every key is optional.

| key | meaning |
|---|---|
| `copy` | Basename globs. Matching gitignored files in the primary checkout are copied into the new worktree when missing there. `*.example` is never copied. Files inside ignored directories (e.g. `node_modules/`) are not considered. |
| `setup` | Run by `bash -c` in the new workspace's first pane, cwd = the worktree. It runs in a pane so you can see it and it is not bound to the hook's lifetime. |
| `teardown` | Run by `bash -c` synchronously, cwd = the **primary checkout**. herdr fires `worktree.removed` *after* deleting the checkout, so point your script at `$HERDR_LIFECYCLE_WORKTREE` instead of expecting to run inside it. A failure shows a herdr notification and keeps the branch. |
| `deleteBranch` | Default `true`. The branch is deleted when it is merged (`git branch -d`) or every commit is on its upstream. It is kept when it has unpushed work, is checked out elsewhere, or is protected. |
| `protectedBranches` | Added to the built-in list: `main master develop development staging production` + `origin/HEAD`. |

`setup` and `teardown` get these env vars:

| var | value |
|---|---|
| `HERDR_LIFECYCLE_WORKTREE` | worktree path |
| `HERDR_LIFECYCLE_BRANCH` | branch (empty when detached) |
| `HERDR_LIFECYCLE_REPO_ROOT` | primary checkout |
| `HERDR_LIFECYCLE_LABEL` | herdr workspace label |
| `HERDR_LIFECYCLE_WORKSPACE_ID` | herdr workspace id |

Examples:
- [`examples/node-monorepo.lifecycle.json`](examples/node-monorepo.lifecycle.json): copy local `.env*` files, link Doppler from a committed `doppler.yaml`, `pnpm install`.
- [`examples/scripted.lifecycle.json`](examples/scripted.lifecycle.json): delegate to the repo's own `scripts/worktree/setup.sh` / `teardown.sh`.

The plugin ships no setup script of its own. `setup` / `teardown` are commands, so put
anything bigger than a one-liner in a script inside the repo and call it from the config.

## Debug

```bash
herdr plugin log list --plugin ibedwi.lifecycle
```

## Develop

```bash
test/hooks.test.sh                          # stubbed herdr, real temp git repos
BASH_BIN=/bin/bash /bin/bash test/hooks.test.sh   # same, on macOS bash 3.2
```

## License

[MIT](LICENSE)
