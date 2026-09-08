# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Two on-demand helpers hold the detail that used to live here, so read them instead of re-deriving it:

- **Adding, changing or removing a `git-shell` command** → the `new-shell-command` skill (`.claude/skills/new-shell-command/SKILL.md`): naming, the script skeleton, the executable bit, the smoke-test cases, the manual SSH walkthrough.
- **Reviewing a change to any shell script, `sshd_config` or the `Containerfile`** → the `shell-injection-reviewer` subagent (`.claude/agents/shell-injection-reviewer.md`): this repository's threat model in full, plus the accepted risks not worth reporting.

## What this is

A container image (Alpine-based) that runs an SSH-only Git server. Users authenticate via SSH public key and are dropped into a restricted `git-shell` that only exposes the custom commands in `git-shell-commands/`. Bare repositories live under `/srv/git` inside the container, backed by a mounted volume. There is no application code to compile — this repo *is* the container image definition (Dockerfile/Containerfile, entrypoint scripts, sshd config, and shell commands).

## Build & run

```sh
docker build --tag git-server:latest --file Dockerfile .     # Docker
buildah build --tag git-server:latest --file Containerfile . # Podman/Buildah
```

`Dockerfile` is a symlink to `Containerfile` (same content, two build tool entry points) — edit `Containerfile`, there is nothing to mirror.

Run (requires a volume for `/srv/git`; SSH host key volume is optional):

```sh
docker run -d --name git-server \
    --env GIT_USER_UID=1000 \
    --env GIT_USER_GID=1000 \
    --env SSH_PUBLIC_KEYS_URL=https://url.to.authorized.keys \
    --publish 2222:22 \
    --volume git-repository:/srv/git \
    git-server:latest
```

## Checks

There is no test suite. The image is the artifact, so the checks are a static one and an end-to-end one:

- `shellcheck --shell=sh`, wired to a pre-commit hook via `lefthook.yml`. Run `lefthook install` once per clone. The tree is clean at `--severity=style`; suppress a deliberate exception at its call site with `# shellcheck disable=SCxxxx` and a comment saying why. Because most scripts here are named after the verb they implement rather than ending in `.sh`, the hook's `glob` is path-shaped — a new directory holding scripts needs an entry in `lefthook.yml`.
- `scripts/smoke-test.sh` — starts a throwaway container and drives every command over SSH, rejection cases included. **Adding a command means adding cases to it.**

```sh
docker build --tag git-server:test --file Containerfile .
IMAGE=git-server:test ./scripts/smoke-test.sh
```

CI lives in `.github/workflows/`. `ci.yml` builds the image on `main` and on pull requests — natively on both `linux/amd64` and `linux/arm64` — and runs `scripts/smoke-test.sh` against each. `image.yml` publishes `ghcr.io/ptcookie/git-server` on a `v*` tag as a single multi-platform manifest; deployment stays manual (see README.md#deployment). GitHub is only a mirror of `git.ptcookie.net`, so **no workflow may write to the repository** — a commit a workflow pushes is erased by the next mirror push.

## Architecture

**Boot sequence** (`entrypoint.sh` → `10-setup.sh` → `sshd -D`):

1. `entrypoint.sh` is the container `ENTRYPOINT`. It runs every executable `*.sh` file in `/entrypoint.d/`, in sorted (`sort -V`) order, then `exec`s the container `CMD` (`/usr/sbin/sshd -D`). This is a plugin-style setup: to add another provisioning step, drop a new numbered script (e.g. `20-foo.sh`) into `/entrypoint.d/` (add a `COPY` for it in both Dockerfile/Containerfile) rather than editing `entrypoint.sh`.
2. `10-setup.sh` does the actual provisioning on each container start:
   - If `GIT_USER_UID`/`GIT_USER_GID` are set, deletes and recreates the `git` user/group with those IDs (so bind-mounted repo ownership matches the host).
   - Fixes ownership/permissions under `GIT_REPOSITORIES_PATH` (`/srv/git`), then symlinks every valid bare repo found there into the `git` user's home directory (this is what makes repos reachable by relative path over `git-shell`).
   - If `SSH_PUBLIC_KEYS_URL` is set, downloads it to `~/.ssh/authorized_keys` (fetch failures only warn, they don't fail the container).
   - If `SSH_HOST_KEYS_PATH` is set and populated, replaces the generated SSH host keys with those from the mounted path (for persistent host identity across container recreation).

**SSH access model**: `sshd_config` disables password auth, keyboard-interactive auth, and TCP/agent forwarding — pubkey auth only, and the shell is locked to `git-shell` (set at user creation, see `Containerfile`/`Dockerfile`). SSH clients can never get an interactive shell — they either run `git-upload-pack`/`git-receive-pack` directly, or (interactively) they land in the `help` menu from `git-shell-commands/`.

**`git-shell-commands/` — the entire admin surface for repo management**, invoked as `ssh git@host <command> [args]` or interactively inside `git-shell`.

Every repo command is a file named `git-<verb>`, reachable both ways: git-shell rewrites `git foo` into the `git-foo` **filename** for `ssh git@host git foo`, and the `git` dispatcher script resolves `git <verb>` to the sibling file when typed at the interactive `git>` prompt. `ls`, `mv` and `rm` are deliberately *not* `git-*` — they are filesystem-shaped verbs, and `git mv`/`git rm` already mean something else in git.

The dispatcher **must never fall back to the real `git` binary** — `git -c alias.x='!sh' x` would hand out arbitrary command execution and defeat the restricted shell.

Each command documents itself via `--help`; run `help NAME` rather than re-reading the script. What matters here is which security property each one carries.

| Command | Does | Carries |
|---|---|---|
| `git-init NAME OWNER [DESC] [SECTION]` | Bare repo, hooks, cgit metadata, `~` symlink | Rolls the whole thing back if any step fails |
| `git-import URL NAME OWNER [DESC] [SECTION]` | `git clone --mirror` plus the same post-init steps | URL schemes whitelisted (`https`, `http`, `git`, `ssh`): `ext::` is arbitrary command execution and a leading `-` is option injection |
| `git-config [NAME\|--global] [KEY [VALUE]]` | Reads/sets a repo config, or the global one | Scope always pinned (`--local`/`--global`) so reads never fall through; no `KEY` opens an editor, which needs a TTY |
| `git-info NAME`, `git-head NAME [BRANCH]` | Metadata/HEAD; show or set the default branch | `git-head` refuses a branch that does not exist |
| `git-gc [--aggressive] [NAME]`, `git-fsck [NAME]` | Maintenance over one repo or all of them | — |
| `ls` | Valid bare repos, without the `.git` suffix | Output feeds straight back into the other commands |
| `mv CURRENT NEW`, `rm NAME` | Rename/delete, re-syncing the `~` symlink | `mv` asks yes/no, `rm` makes you type the name back; both take `--yes` |
| `help [command]` | Lists executable files, delegates to `NAME --help` | **New commands are picked up automatically** if executable and implementing `--help` |

All commands assume the fixed path `/srv/git` (not `$GIT_REPOSITORIES_PATH`), defined once as `REPOSITORIES_PATH` in `common.sh`.

**`git-shell-commands/common.sh`**: shared helpers (`repo_name`, `repo_dir`, `require_repository`, `link_repo`, `install_hooks`, `set_metadata`, `confirm`, `run_over_repositories`, ...). It is **intentionally not executable** so that `help` does not list it and git-shell cannot run it (git-shell also rejects command names containing a dot). `repo_name` is the security boundary: it strips a trailing `.git` and rejects anything that could escape `/srv/git`.

**`hooks/post-receive`**: template hook copied into every new repo by `git-init` (alongside git's own sample hooks) — maintains a cgit `agefile` for idle-time sorting and force-pushes to any `mirror.remote`. It lands with the execute bit set, so it *is* live in new repos.

## Conventions to follow when editing shell scripts

- POSIX `sh`, not bash (`#!/bin/sh`, no bashisms). A bashism in an Alpine image is a portability bug, not a style preference.
- `set -eu` (or `set -ex`/`set -eux` for verbose build-time steps) at the top of scripts.
- Tab indentation, matching the existing `# vim: sw=4:ts=4:et` modeline where present.
- Never build a path out of a user-supplied name by hand. Source `common.sh` and go through `repo_name` / `repo_dir`, which is what keeps `../..` out of `/srv/git`.
- Never interpolate user input into a heredoc or an `eval`. Write repo metadata with `git config`, which quotes for you.
- Quote every expansion, and give every new command a `usage()` plus an `-h|--help` case — that is what `help` prints.
- Anything destructive gets a confirmation and a `--yes` escape hatch; check `[ -t 0 ]` before prompting, since `ssh git@host <cmd>` has no TTY.

**Trust model**: every user shares the one `git` account, so any of them can edit any repo's config. `git-config --edit` drops into `vi`, which can spawn a shell (`:!cmd`) — that is an accepted property of this design, not a bug to be surprised by. Do not add anything that assumes users are isolated from each other.
