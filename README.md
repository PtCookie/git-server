# Git Server Container

Container image for Git and SSH server.

## Build

```sh
# Use podman build
podman build -t git-server:latest -f Containerfile

# Or buildah
buildah build -t git-server:latest -f Containerfile
```

## Run

Make volume and secret.

```sh
podman volume create git-repository

podman secret create ssh /path/to/authorized_keys
```

Run container.

```sh
podman run -d -p 2222:22 \
    --name git-server 
    --volume git-repository:/srv/git \
    --secret ssh,target=/home/git/.ssh/authorized_keys,uid=1000,gid=1000,mode=0600 \
    --env GIT_USER_UID=1000
    --env GIT_USER_GID=1000
    git-server:latest
```

## License

MIT &copy; [PtCookie](https://blog.ptcookie.dev)

Softwares in container image may be under their own licenses.

## Mics

Inspired by [git-server-docker](https://github.com/rockstorm101/git-server-docker/)

