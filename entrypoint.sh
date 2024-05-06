#!/bin/sh
# vim:sw=4:ts=4:et

set -eu

info() {
	echo "$0: $@"
}

warn() {
	echo "$0: WARN: $@"
}

error() {
	echo "$0: ERR: $@" 1>&2
}

ENTRYPOINT_DIR="/entrypoint.d/"

if [ -d "$ENTRYPOINT_DIR" ]; then
	info "Perform container configuration."

	find "$ENTRYPOINT_DIR" -follow -type f -print | sort -V | while read -r f; do
		case "$f" in
		*.sh)
			if [ -x "$f" ]; then
				info "Launch $f."
				"$f"
			else
				warn "Ignored $f, not executable."
			fi
			;;
		*) warn "Ignored $f." ;;
		esac
	done

	info "Container configuration complete."
else
	error "Configuration directory $ENTRYPOINT_DIR not found."
	exit 1
fi

exec "$@"
