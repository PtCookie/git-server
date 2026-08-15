#!/bin/sh
# vim: sw=4:ts=4:et
#
# Shared helpers for the git-shell commands.
#
# This file is intentionally NOT executable: 'help' only lists executable
# files, and git-shell refuses command names containing a dot, so it never
# shows up as (nor can be run as) a command itself.
#
# Source it from a command with:
#     . "$(dirname "$0")/common.sh"

# The single place where the repository path is hardcoded.
REPOSITORIES_PATH=/srv/git

PROGRAM_NAME="$(basename "$0")"

warn() {
	echo "${PROGRAM_NAME}: $*" >&2
}

die() {
	warn "$*"
	exit 1
}

die_usage() {
	warn "$*"
	echo "Run 'help ${PROGRAM_NAME}' to see usage." >&2
	exit 1
}

# Strip a trailing '.git' and reject anything that could escape
# ${REPOSITORIES_PATH} or confuse git.  Prints the bare name.
#
# Callers must use it as:  NAME="$(repo_name "$1")" || exit 1
repo_name() {
	_name="${1%.git}"

	case "$_name" in
	'' | [!A-Za-z0-9_]* | *..* | *[!A-Za-z0-9._-]*)
		echo "${PROGRAM_NAME}: invalid repository name '$1'." >&2
		echo "Names must start with a letter or digit and contain only letters, digits, '.', '_' and '-'." >&2
		return 1
		;;
	esac

	printf '%s\n' "$_name"
}

repo_dir() {
	printf '%s/%s.git\n' "$REPOSITORIES_PATH" "$1"
}

is_repository() {
	git -C "$1" rev-parse --git-dir >/dev/null 2>&1
}

require_repository() {
	if [ ! -d "$(repo_dir "$1")" ]; then
		echo "${PROGRAM_NAME}: repository '$1' does not exist." >&2
		echo "Run 'ls' to see available repositories." >&2
		return 1
	fi
}

require_no_repository() {
	if [ -e "$(repo_dir "$1")" ]; then
		echo "${PROGRAM_NAME}: repository '$1' already exists." >&2
		return 1
	fi
}

# List the bare repository names (without the '.git' suffix) found under
# ${REPOSITORIES_PATH}.
list_repositories() {
	for _entry in "${REPOSITORIES_PATH}"/*; do
		[ -d "$_entry" ] || continue
		is_repository "$_entry" || continue

		_base="$(basename "$_entry")"
		printf '%s\n' "${_base%.git}"
	done
}

# Run ACTION over one repository, or over every repository when no name is
# given.  ACTION is a shell function called with NAME and DIR; a failing one
# does not stop the run, it is collected and reported at the end.
#
#     run_over_repositories ACTION [NAME]
run_over_repositories() {
	_action="$1"
	shift

	if [ $# -ge 1 ]; then
		_targets="$(repo_name "$1")" || return 1
		require_repository "$_targets" || return 1
	else
		_targets="$(list_repositories)"
	fi

	if [ -z "$_targets" ]; then
		echo "No repositories."
		return 0
	fi

	_failed=''

	for _target in $_targets; do
		echo "==> ${_target}"

		if ! "$_action" "$_target" "$(repo_dir "$_target")"; then
			_failed="${_failed} ${_target}"
		fi
	done

	if [ -n "$_failed" ]; then
		echo "${PROGRAM_NAME}: failed for:${_failed}" >&2
		return 1
	fi
}

# Symlink a repository into the home directory so that it is reachable by a
# relative path over git-shell.  '-f' replaces a stale link, '-n' keeps ln
# from following an existing link into the repository itself.
link_repo() {
	ln -sfn "$(repo_dir "$1")" "${HOME}/$1.git"
}

unlink_repo() {
	rm -f "${HOME}/$1.git"
}

# Copy the hook templates into a fresh repository and enable post-update.
install_hooks() {
	_dir="$1"

	if [ -d "${HOME}/hooks" ]; then
		for _hook in "${HOME}"/hooks/*; do
			[ -f "$_hook" ] || continue

			cp "$_hook" "${_dir}/hooks/"
			chmod +x "${_dir}/hooks/$(basename "$_hook")"
		done
	else
		warn "hook templates not found in ${HOME}/hooks."
	fi

	if [ -f "${_dir}/hooks/post-update.sample" ]; then
		mv "${_dir}/hooks/post-update.sample" "${_dir}/hooks/post-update"
		chmod +x "${_dir}/hooks/post-update"
	fi
}

# Write the cgit metadata.  Values go through 'git config' instead of a
# heredoc so that they are quoted and never evaluated by the shell.
set_metadata() {
	_dir="$1"
	_name="$2"
	_owner="$3"
	_desc="$4"
	_section="$5"

	git -C "$_dir" config cgit.name "$_name"
	git -C "$_dir" config cgit.owner "$_owner"

	if [ -n "$_desc" ]; then
		git -C "$_dir" config cgit.desc "$_desc"
		printf '%s\n' "$_desc" >"${_dir}/description"
	else
		git -C "$_dir" config --unset cgit.desc 2>/dev/null || true
	fi

	if [ -n "$_section" ]; then
		git -C "$_dir" config cgit.section "$_section"
	else
		git -C "$_dir" config --unset cgit.section 2>/dev/null || true
	fi
}

# Ask for a yes/no confirmation.  Returns non-zero unless the answer is yes.
confirm() {
	if [ ! -t 0 ]; then
		echo "${PROGRAM_NAME}: no terminal to read a confirmation from." >&2
		echo "Re-run with '--yes' to confirm non-interactively." >&2
		return 1
	fi

	printf '%s [yes|No] ' "$1"
	read -r _answer || _answer=''

	case "$_answer" in
	[Yy] | [Yy][Ee][Ss])
		return 0
		;;
	esac

	echo "Cancelled."
	return 1
}

# Ask the user to type a repository name back.  Used for destructive actions
# where a stray 'y' should not be enough.
confirm_name() {
	if [ ! -t 0 ]; then
		echo "${PROGRAM_NAME}: no terminal to read a confirmation from." >&2
		echo "Re-run with '--yes' to confirm non-interactively." >&2
		return 1
	fi

	printf "Type the repository name '%s' to confirm: " "$1"
	read -r _answer || _answer=''

	if [ "$_answer" != "$1" ]; then
		echo "Name does not match. Cancelled."
		return 1
	fi
}
