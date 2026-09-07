FROM docker.io/library/alpine:3.24

# Image metadata. `source` names the origin; the GHCR publish overrides it
# with the GitHub mirror so that the package links to a browsable repository
# (see .github/workflows/image.yml).
LABEL org.opencontainers.image.title="git-server" \
      org.opencontainers.image.description="SSH-only Git server with a restricted git-shell" \
      org.opencontainers.image.source="https://git.ptcookie.net/git-server.git" \
      org.opencontainers.image.licenses="MIT"

# Install packages
RUN set -ex; \
    apk add --no-cache git openssh curl

# Generate SSH host keys
RUN ssh-keygen -A

# Copy sshd config
COPY sshd_config /etc/ssh/

# Set environment variables
ENV GIT_USER=git
ENV GIT_GROUP=git
ENV GIT_HOME=/home/${GIT_USER}
ENV GIT_REPOSITORIES_PATH=/srv/git

# Create git user
RUN set -eux; \
    adduser -h "${GIT_HOME}" -g "git daemon user" -D -s "$(which git-shell)" "${GIT_USER}"; \
    addgroup "${GIT_USER}" "${GIT_GROUP}"; \
    echo "${GIT_USER}:1q2w3e4r" | chpasswd

# Copy git-shell commands and hooks
COPY git-shell-commands ${GIT_HOME}/git-shell-commands
COPY hooks ${GIT_HOME}/hooks

# Copy gitconfig
COPY .gitconfig ${GIT_HOME}/.gitconfig

# Delete message of the day
RUN rm /etc/motd

# Set up entrypoint script and directory
RUN set -eux; \
    mkdir /entrypoint.d
COPY entrypoint.sh /
COPY 10-setup.sh /entrypoint.d

EXPOSE 22
VOLUME ["/srv/git"]

CMD ["/usr/sbin/sshd", "-D"]
ENTRYPOINT ["/entrypoint.sh"]
