# Git Server Container

Container image for Git and SSH server.

## Build

```sh
# Use docker build
docker build --tag git-server:latest --file Dockerfile .
```

```sh
# Use podman or buildah
buildah build --tag git-server:latest --file Containerfile .
```

## Run

Make volume for git repository.

```sh
docker volume create git-repository
```

```sh
podman volume create git-repository
```

Optionally, make volume for SSH host keys, and copy keys to volume.

```sh
docker volume create git-ssh-keys
```

```sh
podman volume create git-ssh-keys
```

Run container.

```sh
docker run -d --name git-server \
    --env GIT_USER_UID=1000 \
    --env GIT_USER_GID=1000 \
    --env SSH_PUBLIC_KEYS_URL=https://url.to.authorized.keys \
    # --env SSH_HOST_KEYS_PATH=/tmp/host-keys \
    --publish 2222:22 \
    --volume git-repository:/srv/git \
    # --volume git-ssh-keys:/tmp/host-keys:ro \
    git-server:latest
```

```sh
podman run -d --name git-server \
    --env GIT_USER_UID=1000 \
    --env GIT_USER_GID=1000 \
    --env SSH_PUBLIC_KEYS_URL=https://url.to.authorized.keys \
    # --env SSH_HOST_KEYS_PATH=/tmp/host-keys \
    --publish 2222:22 \
    --volume git-repository:/srv/git \
    # --volume git-ssh-keys:/tmp/host-keys:ro \
    git-server:latest
```

## Usage

Repositories are managed over SSH. Every repository command can be written either
as `git <subcommand>` or as `git-<subcommand>`, both in a one-shot SSH call and in
an interactive session.

```sh
ssh -p 2222 git@localhost git init my-repo alice "My repository" tools
ssh -p 2222 git@localhost ls
git clone ssh://git@localhost:2222/my-repo.git
```

An interactive session drops into a restricted shell. Run `help` there, or
`help COMMAND` for the usage of a single command.

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
| `mv [--yes] CURRENT NEW` | Rename a repository |
| `rm [--yes] NAME` | Remove a repository |
| `help [COMMAND]` | Show available commands, or the usage of one |

`mv` and `rm` ask for a confirmation, which needs an interactive session; pass
`--yes` to run them from a script. Opening a config in an editor
(`git config NAME` with no key) also needs an interactive session — otherwise
pass the key and value directly.

Every user shares the single `git` account, so anyone with an authorized key can
manage every repository.

## License

MIT &copy; [PtCookie](https://devlog.ptcookie.net)

Softwares in container image may be under their own licenses.

## Mics

Inspired by [git-server-docker](https://github.com/rockstorm101/git-server-docker/)
