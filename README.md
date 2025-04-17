# Git Server Container

Container image for Git and SSH server.

## Build

```sh
# Use docker build
docker build --tag git-server:latest --file Containerfile .

# Use podman or buildah
buildah build --tag git-server:latest --file Containerfile .
```

## Run

Make volume for git repository.

```sh
docker volume create git-repository
podman volume create git-repository
```

Run container.

```sh
docker run -d --name git-server \
    --env GIT_USER_UID=1000 \
    --env GIT_USER_GID=1000 \
    --env SSH_PUBLIC_KEYS_URL=https://url.to.authorized.keys \
    --publish 2222:22 \
    --volume git-repository:/srv/git \
    git-server:latest

podman run -d --name git-server \
    --env GIT_USER_UID=1000 \
    --env GIT_USER_GID=1000 \
    --env SSH_PUBLIC_KEYS_URL=https://url.to.authorized.keys \
    --publish 2222:22 \
    --volume git-repository:/srv/git \
    git-server:latest
```

## License

MIT &copy; [PtCookie](https://devlog.ptcookie.net)

Softwares in container image may be under their own licenses.

## Mics

Inspired by [git-server-docker](https://github.com/rockstorm101/git-server-docker/)
