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

## License

MIT &copy; [PtCookie](https://devlog.ptcookie.net)

Softwares in container image may be under their own licenses.

## Mics

Inspired by [git-server-docker](https://github.com/rockstorm101/git-server-docker/)
