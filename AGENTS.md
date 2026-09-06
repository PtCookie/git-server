# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A container image (Alpine-based) that runs an SSH-only Git server. Users authenticate via SSH public key and are dropped into a restricted `git-shell` that only exposes the custom commands in `git-shell-commands/`. Bare repositories live under `/srv/git` inside the container, backed by a mounted volume. There is no application code to compile — this repo *is* the container image definition (Dockerfile/Containerfile, entrypoint scripts, sshd config, and shell commands).

## Build & run

```sh
# Docker
docker build --tag git-server:latest --file Dockerfile .

# Podman/Buildah
buildah build --tag git-server:latest --file Containerfile .
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

There is no test suite or linter configured; validate changes by building the image and exercising it via SSH/git-shell (see "Testing changes" below).

CI lives in `.github/workflows/`. `ci.yml` builds the image on `main` and on pull requests — natively on both `linux/amd64` and `linux/arm64` — and runs `scripts/smoke-test.sh` against each. `image.yml` publishes `ghcr.io/ptcookie/git-server` on a `v*` tag as a single multi-platform manifest; deployment stays manual (see README.md#deployment). GitHub is only a mirror of `git.ptcookie.net`, so **no workflow may write to the repository** — a commit a workflow pushes is erased by the next mirror push.

## Architecture

**Boot sequence** (`entrypoint.sh` → `10-setup.sh` → `sshd -D`):

1. `entrypoint.sh` is the container `ENTRYPOINT`. It runs every executable `*.sh` file in `/entrypoint.d/`, in sorted (`sort -V`) order, then `exec`s the container `CMD` (`/usr/sbin/sshd -D`). This is a plugin-style setup: to add another provisioning step, drop a new numbered script (e.g. `20-foo.sh`) into `/entrypoint.d/` (add a `COPY` for it in both Dockerfile/Containerfile) rather than editing `entrypoint.sh`.
2. `10-setup.sh` does the actual provisioning on each container start:
   - If `GIT_USER_UID`/`GIT_USER_GID` are set, deletes and recreates the `git` user/group with those IDs (so bind-mounted repo ownership matches the host).
   - Fixes ownership/permissions under `GIT_REPOSITORIES_PATH` (`/srv/git`), then symlinks every valid bare repo found there into the `git` user's home directory (this is what makes repos reachable by relative path over `git-shell`).
   - If `SSH_PUBLIC_KEYS_URL` is set, downloads it to `~/.ssh/authorized_keys` (fetch failures only warn, they don't fail the container).
   - If `SSH_HOST_KEYS_PATH` is set and populated, replaces the generated SSH host keys with those from the mounted path (for persistent host identity across container recreation).

**SSH access model**: `sshd_config` disables password auth, keyboard-interactive auth, and TCP/agent forwarding — pubkey auth only, and the shell is locked to `git-shell` (set at user creation, see `Containerfile`/`Dockerfile`). This means SSH clients can never get an interactive shell — they either run `git-upload-pack`/`git-receive-pack` directly, or (interactively) they land in the `help` menu from `git-shell-commands/`.

**`git-shell-commands/` — the entire admin surface for repo management**, invoked as `ssh git@host <command> [args]` or interactively inside `git-shell`.

*Two spellings, one command.* Every repo command is a file named `git-<verb>`, and each one is reachable both ways:

- Non-interactive (`ssh git@host git init foo alice`): git-shell itself rewrites `git foo` into `git-foo` before looking the command up, so the `git-<verb>` **filename** is what makes this work. A `git ls` would fail, because no `git-ls` file exists.
- Interactive (typed at the `git>` prompt): no rewrite happens, so the `git` dispatcher script resolves `git <verb>` to the sibling `git-<verb>` file and `exec`s it.

The dispatcher **must never fall back to the real `git` binary** — `git -c alias.x='!sh' x` would hand out arbitrary command execution and defeat the restricted shell.

`ls`, `mv` and `rm` are deliberately *not* `git-*`: they are filesystem-shaped verbs, and `git mv`/`git rm` already mean something else in git.

Commands:
   - `git-init NAME OWNER [DESC] [SECTION]` — creates a bare repo at `/srv/git/NAME.git`, copies hooks from `~/hooks/`, enables `post-update`, writes cgit metadata (`[cgit] section/name/owner/desc`) plus the `description` file, symlinks it into `~`. Rolls the whole thing back if any step fails.
   - `git-config [NAME|--global] [KEY [VALUE]]` — reads/sets a repo config (or the global one). Without a `KEY` it opens an editor, which requires a TTY. Scope is always pinned (`--local`/`--global`) so reads never fall through to the global config.
   - `git-info NAME` — owner/desc/section, HEAD, ref counts, last commit, size. Warns when HEAD points at a branch that does not exist.
   - `git-head NAME [BRANCH]` — shows or sets the default branch; refuses a branch that does not exist.
   - `git-gc [--aggressive] [NAME]` / `git-fsck [NAME]` — maintenance over one repo or all of them.
   - `git-import URL NAME OWNER [DESC] [SECTION]` — `git clone --mirror` + the same post-init steps. URL schemes are whitelisted (`https`, `http`, `git`, `ssh`): `ext::` is arbitrary command execution and a leading `-` is option injection.
   - `ls` — lists valid bare repos under `/srv/git`, without the `.git` suffix so the output can be fed straight back into the other commands.
   - `mv CURRENT NEW` / `rm NAME` — rename/delete a repo and re-sync the `~` symlink. `mv` asks yes/no, `rm` makes you type the repo name back; both take `--yes` for non-interactive use.
   - `help [command]` — lists executable files in its own directory, then delegates `help NAME` to `NAME --help`. **New commands are picked up automatically** as long as the file is executable and implements `--help`; there is no list to update.
   - All commands assume the fixed path `/srv/git` (not `$GIT_REPOSITORIES_PATH`), defined once as `REPOSITORIES_PATH` in `common.sh`.

**`git-shell-commands/common.sh`**: shared helpers (`repo_name`, `repo_dir`, `require_repository`, `link_repo`, `install_hooks`, `set_metadata`, `confirm`, `run_over_repositories`, ...). It is **intentionally not executable** so that `help` does not list it and git-shell cannot run it (git-shell also rejects command names containing a dot). `repo_name` is the security boundary: it strips a trailing `.git` and rejects anything that could escape `/srv/git`.

**`hooks/post-receive`**: template hook copied into every new repo by `git-init` (alongside git's own sample hooks) — an example that maintains a cgit `agefile` for idle-time sorting. It lands as `hooks/post-receive` with the execute bit set, so it *is* live in new repos.

## Conventions to follow when editing shell scripts

- POSIX `sh`, not bash (`#!/bin/sh`, no bashisms).
- `set -eu` (or `set -ex`/`set -eux` for verbose build-time steps) at the top of scripts.
- Tab indentation, matching the existing `# vim: sw=4:ts=4:et` modeline where present.
- Never build a path out of a user-supplied name by hand. Source `common.sh` and go through `repo_name` / `repo_dir`, which is what keeps `../..` out of `/srv/git`.
- Never interpolate user input into a heredoc or an `eval`. Write repo metadata with `git config`, which quotes for you.
- Quote every expansion, and give every new command a `usage()` plus an `-h|--help` case — that is what `help` prints.
- Anything destructive gets a confirmation and a `--yes` escape hatch; check `[ -t 0 ]` before prompting, since `ssh git@host <cmd>` has no TTY.

**Trust model**: every user shares the one `git` account, so any of them can edit any repo's config. `git-config --edit` drops into `vi`, which can spawn a shell (`:!cmd`) — that is an accepted property of this design, not a bug to be surprised by. Do not add anything that assumes users are isolated from each other.

## Testing changes

`scripts/smoke-test.sh` is the automated form of the walkthrough below, and is what CI
runs. It starts a throwaway container (its own name, port, and volume, all cleaned up on
exit), provisions it over `SSH_PUBLIC_KEYS_URL` from a key pair it generates, and drives
every command over SSH:

```sh
docker build --tag git-server:test --file Containerfile .
IMAGE=git-server:test ./scripts/smoke-test.sh
```

It needs `docker` (override with `DOCKER=podman`), `ssh`, `git` and `python3` — the last
one serves the `authorized_keys` the container fetches. `SSH_PORT` and `KEYS_PORT` move
the two host ports it binds.

**Adding a command means adding cases to that script**, in the same shape as the existing
ones: the happy path, and whatever it refuses.

The manual equivalent, for poking at something the script does not cover:

```sh
docker build -t git-server:test --file Dockerfile .
docker run -d --name git-server-test \
    --env SSH_PUBLIC_KEYS_URL=<url-to-a-test-authorized_keys> \
    --publish 2222:22 \
    --volume git-repository-test:/srv/git \
    git-server:test
ssh -p 2222 git@localhost git init test-repo someone
ssh -p 2222 git@localhost ls
ssh -p 2222 git@localhost git info test-repo
git clone ssh://git@localhost:2222/~/test-repo.git
```

Worth covering when touching the commands: both spellings (`git init` and `git-init`), an
interactive session (`ssh -t`) for the dispatcher and the confirmation prompts, and the
rejection cases — `git init ../../tmp/evil someone`, `rm ../../srv`,
`git init x someone '$(touch /tmp/pwned)'`.
