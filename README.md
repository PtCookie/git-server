# Git Server Container

An Alpine-based container image that runs an SSH-only Git server. Clients authenticate with an
SSH public key and land in a restricted `git-shell` that exposes nothing but the repository
commands shipped in the image — cloning, pushing and administration all happen over the same SSH
connection, and no client can ever obtain an interactive shell. Bare repositories live under
`/srv/git`, backed by a volume.

Repository metadata (owner, description, section) is written into each bare repository's own
`config` under a `[cgit]` section, and into its `description` file. The image itself only reads
those keys back in `git info`; a web frontend that understands the same convention can be pointed
at the same volume, but nothing here depends on one.

## Features

- **SSH-only access model** — Public-key authentication only. Passwords, keyboard-interactive
  authentication, TCP/agent forwarding and X11 forwarding are all disabled (`sshd_config`), and
  the `git` account's login shell is `git-shell`, so a client can only run
  `git-upload-pack`/`git-receive-pack` or one of the commands below.
- **Repository management over SSH** — `git init`, `git import`, `git info`, `git head`,
  `git config`, `git gc` and `git fsck`, plus `ls`, `du`, `mv`, `rm` and `help`. Every repository
  command is spelled both ways — `git <verb>` and `git-<verb>` — in a one-shot SSH call and in an
  interactive session alike.
- **Safe by construction** — Repository names are validated before they ever become a path, so
  nothing escapes `/srv/git`; `git import` accepts only `https`, `http`, `git` and `ssh` URLs
  (an `ext::` URL would be arbitrary command execution); a `git init` that fails halfway rolls
  the half-created repository back; `mv` and `rm` ask for confirmation and take `--yes` for
  scripts.
- **Self-documenting shell** — `help` lists the executable files in its own directory and
  delegates `help NAME` to `NAME --help`. A command added to the image shows up with its own
  usage text; there is no list to keep in sync.
- **Provisioning on every start** — The `git` user is recreated with the host's UID/GID when
  asked, repository ownership and permissions are fixed, every valid bare repository is symlinked
  into the `git` user's home (and links left behind by removed repositories are pruned),
  `authorized_keys` is fetched from a URL, and the generated SSH host keys are replaced from a
  mounted path.
- **Pluggable entrypoint** — Provisioning is whatever executable `*.sh` files sit in
  `/entrypoint.d/`, run in `sort -V` order. Adding a step means adding a numbered script, not
  editing the entrypoint.
- **Hooks in every new repository** — `git init` and `git import` copy the hook templates from
  the `git` user's `hooks/` directory into the new repository. The bundled `post-receive` keeps
  an agefile (`info/web/last-modified`) up to date and force-pushes to any mirror remotes
  configured for the repository.
- **Multi-platform image** — Published to GHCR on every `v*` tag as one manifest covering
  `linux/amd64` and `linux/arm64`.

Every user shares the single `git` account, so anyone with an authorized key can manage every
repository — including editing another repository's config. `git config NAME` with no key opens
an editor, and an editor can spawn a shell; that is a property of this design, not an oversight.

## Usage

### Container image

```sh
docker pull ghcr.io/ptcookie/git-server:latest
```

Create a volume for the repositories.

```sh
docker volume create git-repository
```

```sh
podman volume create git-repository
```

Optionally create a second volume for the SSH host keys and copy a set of keys into it, so that
the server keeps its identity across container recreation.

```sh
docker volume create git-ssh-keys
```

```sh
podman volume create git-ssh-keys
```

Run the container.

```sh
docker run --detach --name git-server \
    --env GIT_USER_UID=1000 \
    --env GIT_USER_GID=1000 \
    --env SSH_PUBLIC_KEYS_URL=https://url.to.authorized.keys \
    --publish 2222:22 \
    --volume git-repository:/srv/git \
    ghcr.io/ptcookie/git-server:latest
```

```sh
podman run --detach --name git-server \
    --env GIT_USER_UID=1000 \
    --env GIT_USER_GID=1000 \
    --env SSH_PUBLIC_KEYS_URL=https://url.to.authorized.keys \
    --publish 2222:22 \
    --volume git-repository:/srv/git \
    ghcr.io/ptcookie/git-server:latest
```

To use the host key volume, add these two arguments to either command — the path is arbitrary,
the environment variable and the mount just have to agree:

```sh
    --env SSH_HOST_KEYS_PATH=/tmp/host-keys \
    --volume git-ssh-keys:/tmp/host-keys:ro \
```

Repository paths are resolved relative to the `git` user's home, where every repository is
symlinked, so the short SCP-like form works as-is:

```sh
git clone git@localhost:my-repo.git
```

On a non-default port, where the `ssh://` form is the only one that can carry it, the path has to
say so explicitly — a bare `ssh://host:port/my-repo.git` is an absolute path and does not
resolve:

```sh
git clone ssh://git@localhost:2222/~/my-repo.git
```

### Configuration

`GIT_USER_UID`, `GIT_USER_GID`, `SSH_PUBLIC_KEYS_URL` and `SSH_HOST_KEYS_PATH` are the settings
worth passing at run time; the rest are set by the image itself and are listed because the
provisioning script and the shell commands use them.

| Variable | Default | Description |
| --- | --- | --- |
| `GIT_USER_UID` | _(unset)_ | Recreate the `git` user with this UID, so that repository ownership matches the host |
| `GIT_USER_GID` | `GIT_USER_UID` | Same, for the group. Falls back to the UID when only that is given |
| `SSH_PUBLIC_KEYS_URL` | _(unset)_ | Downloaded to `~/.ssh/authorized_keys` on every start |
| `SSH_HOST_KEYS_PATH` | _(unset)_ | Directory holding `ssh_host_*` files that replace the generated host keys |
| `GIT_REPOSITORIES_PATH` | `/srv/git` | Repository root that gets provisioned. Declared as a `VOLUME` in the image |
| `GIT_USER` / `GIT_GROUP` | `git` / `git` | Account that owns the repositories and that clients log in as |
| `GIT_HOME` | `/home/git` | Home directory holding the repository symlinks, `git-shell-commands/` and `hooks/` |

`GIT_REPOSITORIES_PATH` only tells the provisioning script which directory to fix up and link
from; the repository commands have `/srv/git` compiled in. Mount the volume elsewhere and the
commands will not follow — change the mount, not the variable.

`authorized_keys` is refetched on every start, which makes the URL the source of truth: a key
added inside the container is lost on the next restart. A missing or unreachable URL is only a
warning, so the container comes up either way — with nobody able to log in.

### Repository management

Repositories are managed over SSH. Every repository command can be written either as
`git <subcommand>` or as `git-<subcommand>`, both in a one-shot SSH call and in an interactive
session.

```sh
ssh -p 2222 git@localhost git init my-repo alice "My repository" tools
ssh -p 2222 git@localhost ls
ssh -p 2222 git@localhost git-info my-repo
```

An interactive session drops into the restricted shell. Run `help` there, or `help COMMAND` for
the usage of a single command.

```sh
ssh -p 2222 -t git@localhost
```

| Command | Description |
| --- | --- |
| `git init NAME OWNER [DESC] [SECTION]` | Create a bare repository |
| `git import URL NAME OWNER [DESC] [SECTION]` | Import a remote repository (`https`, `http`, `git`, `ssh`) |
| `git info NAME` | Show owner, description, HEAD, refs, last commit and size |
| `git head NAME [BRANCH]` | Show or set the default branch |
| `git config [NAME\|--global] [KEY [VALUE]]` | Read or modify a config |
| `git gc [--aggressive] [NAME]` | Compact one or every repository |
| `git fsck [NAME]` | Check the integrity of one or every repository |
| `ls` | List repositories |
| `du [NAME]` | Show the disk usage of one or every repository |
| `mv [--yes] CURRENT NEW` | Rename a repository |
| `rm [--yes] NAME` | Remove a repository |
| `help [COMMAND]` | Show available commands, or the usage of one |

`mv` and `rm` ask for a confirmation, which needs an interactive session; pass `--yes` to run
them from a script. Opening a config in an editor (`git config NAME` with no key) also needs an
interactive session — otherwise pass the key and value directly.

### Repository configuration

Per-repository settings live in the bare repository's own `config` and are read and written with
`git config`, which always pins the scope so that a read never falls through to the global
config.

```sh
ssh -p 2222 git@localhost git config my-repo cgit.desc "My repository"
ssh -p 2222 git@localhost git config my-repo --list
```

| Key | Written by | Description |
| --- | --- | --- |
| `cgit.name` | `git init`, `git import` | Repository name |
| `cgit.owner` | `git init`, `git import` | Owner, shown by `git info` |
| `cgit.desc` | `git init`, `git import` | Description, also written to the `description` file |
| `cgit.section` | `git init`, `git import` | Group heading for a frontend that reads the same keys |
| `mirror.remote` | you, with `git config` | Remote the `post-receive` hook force-pushes to |

A repository with `mirror.remote` set gets every accepted `refs/heads/*` and `refs/tags/*` update
pushed on to that remote, and a ref deleted here is deleted there. The push is a force push: this
server is the source of truth, so a rebase or an amend has to propagate. A failed mirror push is
reported as a warning and never fails the receive. The value is passed straight to `git push`, so
a URL works as well as a configured remote name:

```sh
ssh -p 2222 git@localhost git config my-repo mirror.remote git@github.com:me/my-repo.git
```

The push runs as the `git` user inside the container, which therefore needs whatever credentials
the remote asks for. `git config` sets a single value — setting the same key twice overwrites it
— so more than one mirror means editing the config directly, in an interactive session:

```sh
ssh -p 2222 -t git@localhost git config my-repo --edit
```

## Architecture

The container's `ENTRYPOINT` is `entrypoint.sh`, which runs every executable `*.sh` file in
`/entrypoint.d/` in `sort -V` order and then `exec`s the `CMD` (`sshd -D`). Today that directory
holds one script, `10-setup.sh`, which does the provisioning described under
[Configuration](#configuration) on every start. Extending the boot sequence means dropping in
another numbered script, e.g. `20-foo.sh`.

```
git clone/push ──→ sshd :22 (public key only)
                     └─ git-shell ──→ git-upload-pack / git-receive-pack ──→ /srv/git/NAME.git
                                        └─ post-receive ──→ agefile + mirror.remote force push

ssh git@host CMD ─→ git-shell ──→ ~/git-shell-commands/CMD
                                    └─ git VERB ──→ sibling git-VERB, never the real git binary
```

Repositories are reachable by a relative path (`git@host:my-repo.git`) because every valid bare
repository under `/srv/git` is symlinked into the `git` user's home directory, which is what
`git-shell` resolves paths against.

`git-shell` rewrites `git foo` into `git-foo` before looking a command up, which is what makes
the non-interactive spelling work. Interactively there is no such rewrite, so a `git` dispatcher
script resolves `git <verb>` to its sibling `git-<verb>` and execs it. The dispatcher never falls
back to the real `git` binary — `git -c alias.x='!sh' x` would hand out arbitrary command
execution and defeat the restricted shell.

The shared helpers the commands source, `common.sh`, are deliberately not executable: `help` only
lists executable files, and `git-shell` refuses command names containing a dot, so the file is
neither listed as a command nor runnable as one.

## Build

`Dockerfile` is a symlink to `Containerfile`, so both build tools work from the same definition.

```sh
docker build --tag git-server:latest --file Dockerfile .
```

```sh
buildah build --tag git-server:latest --file Containerfile .
```

The build produces an image for the host's own architecture. If the deployment target differs
(e.g. building on Apple Silicon for an amd64 server), pass `--platform`:

```sh
docker build --platform linux/amd64 --tag git-server:latest --file Dockerfile .
```

It is a single `alpine` stage: `git`, `openssh` and `curl` are installed, host keys are generated
at build time (replaceable at run time via `SSH_HOST_KEYS_PATH`), the `git` user is created with
`git-shell` as its login shell, and `git-shell-commands/` and `hooks/` are copied into its home.

There is no test suite and no linter — the image is the artifact, so the check is that a
container started from it still behaves. `scripts/smoke-test.sh` is that check: it starts a
throwaway container with its own name, port and volume, provisions it over `SSH_PUBLIC_KEYS_URL`
with a key pair it generates, drives every command over SSH — the rejection cases as much as the
happy paths — and cleans up after itself.

```sh
docker build --tag git-server:test --file Containerfile .
IMAGE=git-server:test ./scripts/smoke-test.sh
```

It needs `docker` (override with `DOCKER=podman`), `ssh`, `git` and `python3`, the last one to
serve the `authorized_keys` the container fetches. `SSH_PORT` and `KEYS_PORT` move the two host
ports it binds. Adding a command to the image means adding its cases to that script; see
[AGENTS.md](AGENTS.md) for the manual walkthrough it automates.

`.github/workflows/ci.yml` runs exactly this on `main` and on pull requests, building natively on
both `linux/amd64` and `linux/arm64`.

## Deployment

The image is published to `ghcr.io/ptcookie/git-server` on every `v*` tag as one multi-platform
manifest covering `linux/amd64` and `linux/arm64`. Three tags move with each release — the full
version, its `major.minor` prefix, and `latest`. Pin `ghcr.io/ptcookie/git-server:<version>` if a
rollback path matters.

The registry's OS/Arch list also shows `unknown/unknown` rows next to the two platforms: those
are the SLSA provenance attestations buildx attaches by default, not platforms, and `docker pull`
never resolves them.

Nothing pulls or restarts automatically. Rolling out a new image is a manual `docker pull`
followed by recreating the container (or a `pull` + `up --detach` if it is managed by a compose
file). Run it exactly as in [Usage](#container-image).

Three things decide whether a recreated container is the same server as before:

- The `/srv/git` volume holds every repository — without it, a container replacement is a wipe.
- Without a host key volume and `SSH_HOST_KEYS_PATH`, the host keys are regenerated with the
  image, and every client will refuse to connect until its `known_hosts` entry is replaced.
- `GIT_USER_UID`/`GIT_USER_GID` have to keep matching the ownership of the existing repository
  data; the provisioning script chowns the tree to whatever they say on every start.

## License

MIT &copy; [PtCookie](https://devlog.ptcookie.net)

Softwares in container image may be under their own licenses.

## Misc

Inspired by [git-server-docker](https://github.com/rockstorm101/git-server-docker/)
