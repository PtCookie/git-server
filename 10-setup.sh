#!/bin/sh
# vim:sw=4:ts=4:et

set -eu

warn() {
	echo "$0: WARN: $@"
}

# Set specific UID and GID for the git user
if [ -n "${GIT_USER_UID-}" ]; then

	if [ -z "${GIT_USER_GID-}" ]; then
		GIT_USER_GID="${GIT_USER_UID}"
	fi

	# Recreate git user
	deluser "${GIT_USER}"
	addgroup -g "${GIT_USER_GID}" "${GIT_GROUP}"
	adduser -h "${GIT_HOME}" -g "git daemon user" -D -s "$(which git-shell)" -G "${GIT_GROUP}" -H -u "${GIT_USER_UID}" "${GIT_USER}"
	if ! CHPASSWD=$(echo "${GIT_USER}:1q2w3e4r" | chpasswd 2>&1); then
		echo "$CHPASSWD"
		exit 1
	fi
fi

# Setup repositories
if [ -d "${GIT_REPOSITORIES_PATH}" ]; then
	cd "${GIT_REPOSITORIES_PATH}"/.

	# Fix ownership and permission of repositories
	chown -R "${GIT_USER}":"${GIT_GROUP}" .
	find . -type f -exec chmod u=rwX,go=rX '{}' \;
	find . -type d -exec chmod u=rwx,go=rx '{}' \;

	# Symlink repositories to home directory
	for PATH_ENTRY in ${GIT_REPOSITORIES_PATH}/*; do
		if [ -d "$PATH_ENTRY" ]; then
			if su -s /bin/sh - "${GIT_USER}" -c "git -C ${PATH_ENTRY} rev-parse --git-dir >/dev/null"; then
				ln -sf "${PATH_ENTRY}" "${GIT_HOME}"
			fi
		fi
	done
else
	warn "Directory $GIT_REPOSITORIES_PATH not found."
fi

# Get SSH public keys
if [ -n "${SSH_PUBLIC_KEYS_URL-}" ]; then
	mkdir -p "${GIT_HOME}"/.ssh
	wget -qO "${GIT_HOME}"/.ssh/authorized_keys "${SSH_PUBLIC_KEYS_URL}" || warn "Failed to fetch public keys."
fi

# Set ownership for public keys
if [ -f "${GIT_HOME}"/.ssh/authorized_keys ]; then
	chown -R "${GIT_USER}":"${GIT_GROUP}" "${GIT_HOME}"
else
	warn "There is no authorized keys found."
	warn "Check if server is accessable via other ways."
fi

# Replace SSH host keys if path given
if [ -n "${SSH_HOST_KEYS_PATH-}" ]; then
	if [ -d "${SSH_HOST_KEYS_PATH}" ]; then
		rm -rf /etc/ssh/ssh_host_*
		cp "${SSH_HOST_KEYS_PATH}"/ssh_host_* /etc/ssh/
	else
		warn "Directory $SSH_HOST_KEYS_PATH not found."
		warn "Default SSH host keys will be used instead."
	fi
fi
