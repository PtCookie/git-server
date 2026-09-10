#!/bin/sh
# vim: sw=4:ts=4:et
#
# End-to-end smoke test for the git-server image.
#
# Starts the image the way the deployment starts it -- a git user pinned to a
# host UID/GID and an authorized_keys fetched over HTTP -- then drives every
# git-shell command over SSH.  The rejection cases are as much the point as
# the happy path: the restricted shell is the only thing between an authorized
# key and the host, so a change that quietly loosens it has to fail here.
#
# This is what .github/workflows/ci.yml runs, and the automated form of the
# walkthrough in AGENTS.md:
#
#     docker build --tag git-server:test --file Containerfile .
#     IMAGE=git-server:test ./scripts/smoke-test.sh

set -eu

IMAGE="${IMAGE:-git-server:test}"
DOCKER="${DOCKER:-docker}"
SSH_PORT="${SSH_PORT:-2222}"
KEYS_PORT="${KEYS_PORT:-8000}"

PROGRAM_NAME="$(basename "$0")"

usage() {
	echo "Run the end-to-end smoke test against a git-server image."
	printf '\n'
	echo "Usage : smoke-test.sh"
	printf '\n'
	echo "Environment:"
	echo "  IMAGE      image to test (default: git-server:test)"
	echo "  DOCKER     container CLI to use (default: docker)"
	echo "  SSH_PORT   host port to publish the container's sshd on (default: 2222)"
	echo "  KEYS_PORT  host port serving authorized_keys to the container (default: 8000)"
}

case "${1:-}" in
-h | --help)
	usage
	exit 0
	;;
esac

if [ $# -gt 0 ]; then
	echo "${PROGRAM_NAME}: unexpected argument '$1'." >&2
	echo "Run '${PROGRAM_NAME} --help' to see usage." >&2
	exit 1
fi

die() {
	echo "${PROGRAM_NAME}: $*" >&2
	exit 1
}

for TOOL in "${DOCKER}" ssh ssh-keygen git python3; do
	command -v "${TOOL}" >/dev/null 2>&1 || die "'${TOOL}' not found in PATH."
done

# ---------------------------------------------------------------- fixtures --

CONTAINER="git-server-smoke-$$"
VOLUME="git-server-smoke-$$"
# An explicit template so that TMPDIR is honoured on macOS too, where a
# bare `mktemp -d` ignores it.
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/git-server-smoke.XXXXXX")"
LOG="${WORKDIR}/output"
KEYS_SERVER_PID=

cleanup() {
	_status=$?
	trap - EXIT

	if [ -n "${KEYS_SERVER_PID}" ]; then
		kill "${KEYS_SERVER_PID}" 2>/dev/null || true
		wait "${KEYS_SERVER_PID}" 2>/dev/null || true
	fi

	"${DOCKER}" rm --force --volumes "${CONTAINER}" >/dev/null 2>&1 || true
	"${DOCKER}" volume rm --force "${VOLUME}" >/dev/null 2>&1 || true
	rm -rf "${WORKDIR}"

	exit "${_status}"
}
trap cleanup EXIT INT TERM

# ------------------------------------------------------------------ report --

TESTS_RUN=0
TESTS_FAILED=0

ok() {
	TESTS_RUN=$((TESTS_RUN + 1))
	printf 'ok   %s\n' "$1"
}

not_ok() {
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf 'FAIL %s\n' "$1" >&2
	[ -s "${LOG}" ] || return 0
	sed 's/^/     | /' "${LOG}" >&2
}

# check DESC COMMAND... -- the command's output is kept in ${LOG} so that a
# caller can grep it, and is dumped only when the expectation fails.
check() {
	_desc="$1"
	shift

	if "$@" >"${LOG}" 2>&1; then
		ok "${_desc}"
		return 0
	fi

	not_ok "${_desc}"
	return 1
}

# check_fails DESC COMMAND... -- the mirror image, for the rejection cases.
check_fails() {
	_desc="$1"
	shift

	if "$@" >"${LOG}" 2>&1; then
		not_ok "${_desc}"
		return 1
	fi

	ok "${_desc}"
	return 0
}

# ------------------------------------------------------------------- setup --

ssh_git() {
	ssh -o StrictHostKeyChecking=no \
		-o UserKnownHostsFile=/dev/null \
		-o LogLevel=ERROR \
		-o BatchMode=yes \
		-o ConnectTimeout=5 \
		-i "${WORKDIR}/id_ed25519" \
		-p "${SSH_PORT}" \
		git@127.0.0.1 "$@"
}

in_container() {
	"${DOCKER}" exec "${CONTAINER}" "$@"
}

echo "==> Image: ${IMAGE}"

ssh-keygen -q -t ed25519 -N '' -C "${PROGRAM_NAME}" -f "${WORKDIR}/id_ed25519"

# The container fetches this over HTTP instead of having it mounted, so that
# the SSH_PUBLIC_KEYS_URL path in 10-setup.sh is exercised too.  It has to be
# bound on every interface: the container reaches the host through the bridge
# gateway address, not through loopback.
mkdir "${WORKDIR}/keys"
cp "${WORKDIR}/id_ed25519.pub" "${WORKDIR}/keys/authorized_keys"

(cd "${WORKDIR}/keys" && exec python3 -m http.server "${KEYS_PORT}") >/dev/null 2>&1 &
KEYS_SERVER_PID=$!

echo "==> Starting ${CONTAINER}"

"${DOCKER}" run --detach --name "${CONTAINER}" \
	--add-host host.docker.internal:host-gateway \
	--env GIT_USER_UID=1000 \
	--env GIT_USER_GID=1000 \
	--env "SSH_PUBLIC_KEYS_URL=http://host.docker.internal:${KEYS_PORT}/authorized_keys" \
	--publish "127.0.0.1:${SSH_PORT}:22" \
	--volume "${VOLUME}:/srv/git" \
	"${IMAGE}" >/dev/null

# A successful login means sshd is up *and* the key was fetched, so this one
# loop covers the whole provisioning path.
READY=
TRIES=0
while [ "${TRIES}" -lt 60 ]; do
	if ssh_git ls >/dev/null 2>&1; then
		READY=1
		break
	fi

	if [ "$("${DOCKER}" inspect --format '{{.State.Running}}' "${CONTAINER}" 2>/dev/null)" != "true" ]; then
		break
	fi

	TRIES=$((TRIES + 1))
	sleep 1
done

if [ -z "${READY}" ]; then
	echo "${PROGRAM_NAME}: container never became reachable over SSH." >&2
	"${DOCKER}" logs "${CONTAINER}" >&2 2>&1 || true
	exit 1
fi

echo "==> Ready after ${TRIES}s"
printf '\n'

# ------------------------------------------------------------------- tests --

# Both spellings of the same command.  'git init' only works because git-shell
# rewrites it into the 'git-init' filename; 'git-init' is that filename.
check "git init (rewritten spelling)" \
	ssh_git "git init smoke-a someone 'Smoke test repository' tools" || true

check "git-init (direct spelling)" \
	ssh_git "git-init smoke-b someone" || true

if check "ls lists both repositories" ssh_git ls; then
	if grep -qx 'smoke-a' "${LOG}" && grep -qx 'smoke-b' "${LOG}" && ! grep -q '\.git' "${LOG}"; then
		ok "ls prints names without the .git suffix"
	else
		not_ok "ls prints names without the .git suffix"
	fi
fi

if check "git info reports the metadata" ssh_git "git info smoke-a"; then
	if grep -q '^Owner: *someone$' "${LOG}" &&
		grep -q '^Description: *Smoke test repository$' "${LOG}" &&
		grep -q '^Section: *tools$' "${LOG}"; then
		ok "git info shows owner, description and section"
	else
		not_ok "git info shows owner, description and section"
	fi
fi

# Clone, commit, push.  This is the only test that goes through
# git-upload-pack/git-receive-pack rather than a git-shell command.
GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes -i ${WORKDIR}/id_ed25519"
export GIT_SSH_COMMAND

# The '~/' matters: an ssh:// path is absolute, and the repositories are
# reachable by name only through the symlinks 10-setup.sh and link_repo keep
# in the git user's home.
check "clone over ssh" \
	git clone --quiet "ssh://git@127.0.0.1:${SSH_PORT}/~/smoke-a.git" "${WORKDIR}/clone" || true

check "commit in the clone" \
	git -C "${WORKDIR}/clone" \
	-c user.name="Smoke Test" \
	-c user.email="smoke@example.invalid" \
	-c commit.gpgsign=false \
	commit --quiet --allow-empty --message "Smoke test commit" || true

check "push reaches git-receive-pack" \
	git -C "${WORKDIR}/clone" push --quiet origin HEAD:refs/heads/main || true

# Copied out of ~/hooks by git-init, so a push has to have produced the cgit
# agefile it maintains.
check "post-receive wrote the cgit agefile" \
	in_container test -s /srv/git/smoke-a.git/info/web/last-modified || true

if check "git head reports the default branch" ssh_git "git head smoke-a"; then
	if grep -qx 'main' "${LOG}"; then
		ok "default branch is main"
	else
		not_ok "default branch is main"
	fi
fi

check_fails "git head refuses a branch that does not exist" \
	ssh_git "git head smoke-a nonexistent" || true

# smoke-a has been pushed to by now, so it holds real objects to measure.
if check "du measures every repository" ssh_git du; then
	if grep -qE '^[0-9.]+[KMGT]?[[:space:]]+smoke-a$' "${LOG}" &&
		grep -qE '[[:space:]]smoke-b$' "${LOG}" &&
		grep -qE '[[:space:]]total$' "${LOG}"; then
		ok "du prints a size per repository and a total"
	else
		not_ok "du prints a size per repository and a total"
	fi
fi

if check "du measures a single repository" ssh_git "du smoke-a"; then
	if grep -qE '^[0-9.]+[KMGT]?[[:space:]]+smoke-a$' "${LOG}" &&
		! grep -q 'smoke-b' "${LOG}" && ! grep -q 'total' "${LOG}"; then
		ok "du of one repository omits the others and the total"
	else
		not_ok "du of one repository omits the others and the total"
	fi
fi

# help only finds it if it landed in the image with the execute bit set.
if check "help du prints the usage" ssh_git "help du"; then
	if grep -q 'Usage : du' "${LOG}"; then
		ok "du is executable inside the image"
	else
		not_ok "du is executable inside the image"
	fi
fi

# common.sh is not executable precisely so that it never shows up here.
if check "help lists the commands" ssh_git "help"; then
	if grep -q '^git init$' "${LOG}" && grep -qx 'ls' "${LOG}" && ! grep -q 'common\.sh' "${LOG}"; then
		ok "help hides common.sh"
	else
		not_ok "help hides common.sh"
	fi
fi

# The interactive path: no git-shell rewrite happens there, so 'git info'
# only resolves because of the 'git' dispatcher script.
if check "interactive dispatcher resolves 'git info'" \
	sh -c "printf 'git info smoke-a\nexit\n' | ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes -i '${WORKDIR}/id_ed25519' -p '${SSH_PORT}' -tt git@127.0.0.1"; then
	if grep -q 'Name: *smoke-a' "${LOG}"; then
		ok "interactive session ran the command"
	else
		not_ok "interactive session ran the command"
	fi
fi

# -- rejection cases ---------------------------------------------------------

check_fails "git init rejects a name that escapes /srv/git" \
	ssh_git "git init ../../tmp/evil someone" || true

check_fails "nothing was created outside /srv/git" \
	in_container test -e /tmp/evil.git || true

check_fails "rm rejects a name that escapes /srv/git" \
	ssh_git "rm ../../srv" || true

check "the repositories directory survived" \
	in_container test -d /srv/git/smoke-a.git || true

check_fails "du rejects a name that escapes /srv/git" \
	ssh_git "du ../../srv" || true

check_fails "du refuses a repository that does not exist" \
	ssh_git "du nonexistent" || true

check_fails "du rejects an unknown option" \
	ssh_git "du --bogus" || true

check_fails "du rejects too many arguments" \
	ssh_git "du smoke-a smoke-b" || true

# The dispatcher must never reach the real git binary: an alias is a shell
# escape out of the restricted shell.
check_fails "git -c alias.x='!sh' does not reach the real git" \
	ssh_git "git -c alias.x=!sh x" || true

# A metadata value is written with 'git config', never evaluated.
check "a shell-shaped description is stored verbatim" \
	ssh_git "git init smoke-c someone '\$(touch /tmp/pwned)'" || true

check_fails "the description was not executed" \
	in_container test -e /tmp/pwned || true

if check "the description round-trips" ssh_git "git info smoke-c"; then
	# The literal '$(...)' is the point here, not an expansion.
	# shellcheck disable=SC2016
	if grep -qF '$(touch /tmp/pwned)' "${LOG}"; then
		ok "git info shows the literal description"
	else
		not_ok "git info shows the literal description"
	fi
fi

# Destructive commands need a confirmation, and 'ssh host cmd' has no TTY.
check_fails "rm without --yes refuses without a terminal" \
	ssh_git "rm smoke-b" || true

check "the repository was kept" \
	in_container test -d /srv/git/smoke-b.git || true

# -- rename and remove -------------------------------------------------------

check "mv --yes renames a repository" \
	ssh_git "mv --yes smoke-b smoke-renamed" || true

check "the home symlink follows the rename" \
	in_container test -L /home/git/smoke-renamed.git || true

check_fails "the old home symlink is gone" \
	in_container test -e /home/git/smoke-b.git || true

check "rm --yes removes a repository" \
	ssh_git "rm --yes smoke-renamed" || true

check_fails "the removed repository is gone" \
	in_container test -e /srv/git/smoke-renamed.git || true

check_fails "its home symlink is gone too" \
	in_container test -e /home/git/smoke-renamed.git || true

# ------------------------------------------------------------------ result --

printf '\n'

if [ "${TESTS_FAILED}" -ne 0 ]; then
	echo "${TESTS_FAILED} of ${TESTS_RUN} checks failed." >&2
	exit 1
fi

echo "All ${TESTS_RUN} checks passed."
