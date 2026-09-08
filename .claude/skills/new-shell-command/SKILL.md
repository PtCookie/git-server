---
name: new-shell-command
description: Add a command to git-shell-commands/ following this repository's conventions — the git-<verb> naming that makes both spellings work, common.sh helpers, usage()/--help, confirmations for destructive actions, and the matching smoke-test.sh cases. Use when adding, renaming, or removing a git-shell command, or when a command needs a new flag or argument.
---

# Adding a git-shell command

Every command in `git-shell-commands/` is reachable by an authorized key over SSH, so
"add a command" means "widen the restricted shell". The checklist below is what keeps a
new command consistent with the existing ones and closed to the escapes documented in
`AGENTS.md`.

Read `AGENTS.md` before starting, and read `git-shell-commands/common.sh` plus the
closest existing command as your model:

| The new command… | Model it on |
|---|---|
| creates a repository | `git-init` (rollback trap) |
| clones from a URL | `git-import` (scheme whitelist) |
| reads state | `git-info`, `ls` |
| changes one setting | `git-head`, `git-config` |
| runs over one or all repos | `git-gc`, `git-fsck` (`run_over_repositories`) |
| destroys something | `rm` (`confirm_name`), `mv` (`confirm`) |

## 1. Pick the name

**`git-<verb>` if it acts on a repository.** The filename is load-bearing:
`ssh git@host git foo bar` works because git-shell itself rewrites `git foo` into
`git-foo` before looking the command up. Interactively at the `git>` prompt no rewrite
happens, so the `git` dispatcher resolves `git <verb>` to the sibling `git-<verb>` and
`exec`s it. One file, both spellings, nothing to register.

**A bare name if the verb is filesystem-shaped** — that is why `ls`, `mv` and `rm` are
not `git-*`: `git mv` and `git rm` already mean something else in git.

Constraints on the name:

- Letters, digits and `-` only. Both `git` and `help` reject anything else via a
  `*[!A-Za-z0-9-]*` case, and git-shell refuses a command name containing a dot.
- Do not shadow a real git subcommand with different semantics.
- A non-executable file, or one with a dot, is invisible to `help` — that is how
  `common.sh` stays hidden. Do not rely on that for anything you want callable.

## 2. Write the script

Start from this skeleton. Tab indentation, POSIX `sh`, no bashisms
(`[[`, `local`, `function`, arrays, `echo -e`, `source`, `pipefail`).

```sh
#!/bin/sh
# vim: sw=4:ts=4:et

set -eu

. "$(dirname "$0")/common.sh"

usage() {
	echo "One line saying what this does."
	printf '\n'
	echo "Usage : git verb [--flag] NAME [ARG]"
	echo "        git-verb [--flag] NAME [ARG]"
	printf '\n'
	echo "  --flag  What it changes."
	printf '\n'
	echo "Any extra note, e.g. that a trailing '.git' in NAME is ignored."
}

case "${1:-}" in
-h | --help)
	usage
	exit 0
	;;
esac

# Options first, so that '--' and an unknown '-x' are both handled before any
# operand is read.  Omit this loop entirely if the command takes no flags.
ASSUME_YES=

while [ $# -gt 0 ]; do
	case "$1" in
	-h | --help)
		usage
		exit 0
		;;
	-y | --yes)
		ASSUME_YES=1
		shift
		;;
	--)
		shift
		break
		;;
	-*)
		die_usage "unknown option '$1'."
		;;
	*)
		break
		;;
	esac
done

if [ $# -lt 1 ]; then
	die_usage "no repository name given."
fi

if [ $# -gt 1 ]; then
	die_usage "too many arguments."
fi

# repo_name is the security boundary.  Keep the explicit '|| exit 1': 'set -e'
# is suspended in a condition or on the left of '&&'/'||', and an 'export' or
# similar prefix would make the assignment take the prefix's exit status
# instead of the substitution's.
REPOSITORY_NAME="$(repo_name "$1")" || exit 1
REPOSITORY_DIR="$(repo_dir "${REPOSITORY_NAME}")"

require_repository "${REPOSITORY_NAME}" || exit 1

# ... the actual work ...

echo "Did the thing to ${REPOSITORY_NAME}."
```

### Rules that are not negotiable

- **Never build a path from a name by hand.** `repo_name` then `repo_dir`. No
  `"${REPOSITORIES_PATH}/$1"`, no `"${HOME}/$1.git"`.
- **Quote every expansion.** The one deliberate exception is the unquoted
  `for _target in $_targets` inside `run_over_repositories`, which relies on the
  charset `repo_name` enforces.
- **Never interpolate user input into `eval`, a `sh -c` string, or an unquoted
  heredoc.** Write metadata with `git config` (it quotes for you) and print values with
  `printf '%s\n'`, never `echo`.
- **Put `--` before any user-supplied operand** passed to `git`, `rm`, `mv`, `cp`,
  `ln`, `find`. A value from `repo_name` is charset-safe; an owner, description, section,
  URL or config key is not.
- **Whitelist, do not blacklist**, if the command takes a URL. Copy the `case` from
  `git-import`: `https://?* | http://?* | git://?* | ssh://?*`. `ext::` is arbitrary
  command execution and a leading `-` is option injection.
- **Never reach the real `git` binary as a dispatch target.** `git -c alias.x='!sh' x`
  is a shell escape. (Calling `git` for actual git work — `git -C "$DIR" config …` — is
  of course fine.)
- **Prefix helper-local variables with `_`** if you add anything to `common.sh`. POSIX
  `sh` has no `local`, so an unprefixed name clobbers the caller's.

### If it is destructive

Confirmation plus a `--yes` escape hatch, always:

```sh
if [ -z "${ASSUME_YES}" ]; then
	# Show what is about to be lost first.
	confirm "Delete ${REPOSITORY_NAME}?" || exit 1
	# ...or, for something unrecoverable:
	confirm_name "${REPOSITORY_NAME}" || exit 1
fi
```

`confirm` and `confirm_name` already check `[ -t 0 ]` and fail closed with a pointer to
`--yes`, because `ssh git@host <cmd>` has no TTY. Do not write your own `read` prompt.

### If it creates something in several steps

Use the rollback trap from `git-init`, so a failure halfway does not leave a broken
repository behind:

```sh
INCOMPLETE=1
trap '[ -z "${INCOMPLETE}" ] || rm -rf "${REPOSITORY_DIR}"' EXIT

# ... every step that could fail ...

INCOMPLETE=
```

The trap may only ever delete a path that came from `repo_dir`.

### If it should run over one or all repositories

```sh
action() {
	_name="$1"
	_dir="$2"
	# ...
}

run_over_repositories action "$@"
```

It resolves and validates the name itself, walks everything when given none, and
collects failures instead of stopping at the first.

## 3. Make it executable

```sh
chmod +x git-shell-commands/<name>
```

This is what puts it in `help` and in `git --help`, and what the dispatcher's
`[ -f ] && [ -x ]` test requires. It is easy to forget and the command is simply
invisible without it — confirm the mode is `100755` in `git status`/`git diff`.

No `Containerfile` change is needed: `COPY git-shell-commands ${GIT_HOME}/git-shell-commands`
takes the whole directory. (A new `/entrypoint.d/` script *would* need its own `COPY`.)

No `help` change is needed either — it lists the executable files in its own directory
and delegates `help NAME` to `NAME --help`. That is why `usage()` and the `-h|--help`
case are mandatory: they *are* the documentation.

## 4. Add the smoke-test cases

`scripts/smoke-test.sh` is the only test this repository has, and CI runs it on both
architectures. **A command without cases there is untested, and a rejection that is not
tested regresses silently.** Add, in the same shape as the existing cases:

```sh
# The happy path.
check "git verb does the thing" \
	ssh_git "git verb smoke-a" || true

# Assert the effect, not just the exit status.
check "the thing actually happened" \
	in_container test -e /srv/git/smoke-a.git/some-file || true

# Or grep the output that ${LOG} already holds.
if check "git verb reports the value" ssh_git "git verb smoke-a"; then
	if grep -qx 'expected' "${LOG}"; then
		ok "git verb printed the value"
	else
		not_ok "git verb printed the value"
	fi
fi

# Every rejection the command implements.
check_fails "git verb rejects a name that escapes /srv/git" \
	ssh_git "git verb ../../tmp/evil" || true

check_fails "nothing was created outside /srv/git" \
	in_container test -e /tmp/evil || true
```

Cover at minimum:

- Both spellings, at least once for the new command: `git verb` and `git-verb`.
- The happy path, asserted by its *effect* (`in_container test …`) or by grepping
  `${LOG}`, not by exit status alone.
- The path-escape rejection, plus a check that nothing landed outside `/srv/git`.
- Every other refusal: a missing argument, too many arguments, an unknown option, a
  non-existent repository, and — if it takes a URL — `ext::` and a leading `-`.
- If destructive: that it refuses without `--yes` and no TTY, that the target survived
  that refusal, and that `--yes` works.
- If it touches the `~` symlinks: `in_container test -L /home/git/NAME.git` after, and
  that the stale link is gone.

Use fixtures the script already creates (`smoke-a`, `smoke-b`, `smoke-c`) rather than
adding new ones, and put your block near the related cases, not at the end.

## 5. Verify

`lefthook` runs `shellcheck` on commit, but run it directly while iterating:

```sh
shellcheck --shell=sh --external-sources --source-path=SCRIPTDIR \
	git-shell-commands/<name>
```

Then build and drive the real thing:

```sh
docker build --tag git-server:test --file Containerfile .
IMAGE=git-server:test ./scripts/smoke-test.sh
```

`smoke-test.sh` starts a throwaway container — its own name, port and volume,
all cleaned up on exit — provisions it over `SSH_PUBLIC_KEYS_URL` from a key pair it
generates, and drives every command over SSH. It needs `docker` (override with
`DOCKER=podman`), `ssh`, `git` and `python3`; the last one serves the `authorized_keys`
the container fetches. `SSH_PORT` and `KEYS_PORT` move the two host ports it binds.

### Poking at something the script does not cover

```sh
docker build -t git-server:test --file Dockerfile .
docker run -d --name git-server-test \
	--env SSH_PUBLIC_KEYS_URL=<url-to-a-test-authorized_keys> \
	--publish 2222:22 \
	--volume git-repository-test:/srv/git \
	git-server:test

ssh -p 2222 git@localhost git init test-repo someone   # rewritten spelling
ssh -p 2222 git@localhost git-init test-repo someone   # direct spelling
ssh -p 2222 git@localhost ls
ssh -p 2222 git@localhost help git verb                # the usage() output
ssh -p 2222 -t git@localhost                           # interactive: dispatcher
                                                       # and confirm prompts
git clone ssh://git@localhost:2222/~/test-repo.git
```

Always exercise the refusals by hand too, not just the happy path:

```sh
ssh -p 2222 git@localhost git init ../../tmp/evil someone
ssh -p 2222 git@localhost rm ../../srv
ssh -p 2222 git@localhost "git init x someone '\$(touch /tmp/pwned)'"
ssh -p 2222 git@localhost "git -c alias.x=!sh x"
docker exec git-server-test ls /tmp                    # nothing should be there
```

## 6. Update the docs

- **`AGENTS.md`** — add a bullet under the `git-shell-commands/` "Commands:" list, in
  the same one-line `NAME ARGS — what it does` form. If the command introduces a new
  security consideration, say so where the others are stated.
- **`README.md`** — add it to the command reference if a user-facing command.
- Commit in Conventional Commits form, e.g.
  `feat(git-shell): Add git-verb to do the thing`.

## Removing or renaming a command

Same list, backwards: delete or `git mv` the file, remove its smoke-test cases, and
update `AGENTS.md` and `README.md`. `help` and the `git` dispatcher need no change.
Check nothing else sources or invokes it (`grep -rn '<name>' --exclude-dir=.git .`),
and remember that a rename changes the SSH-visible interface — anything scripted
against `ssh git@host <old-name>` breaks.
