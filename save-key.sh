#!/usr/bin/env bash
# Write an OpenRouter API key to the widget's key file, reading it from stdin
# so it never appears in argv or in `ps`.
#
# Prints one JSON object and exits 0 either way, the same contract credits.sh
# uses, so the panel renders the outcome instead of guessing at an exit code.

set -uo pipefail

readonly CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
readonly KEY_DIR="$CONFIG_HOME/omarchy/openrouter"
readonly KEY_FILE="$KEY_DIR/key"

emit() {
  jq -n "$@"
  exit 0
}

fail() {
  emit --arg error "$1" '{ok: false, error: $error}'
}

command -v jq >/dev/null 2>&1 || {
  printf '{"ok":false,"error":"jq is not installed"}\n'
  exit 0
}

# One line, and only the key on it. A pasted key arrives with a trailing
# newline and sometimes a stray space from the clipboard; neither is part of
# it. `read` returns on that newline rather than waiting for the writer to
# close the pipe, and the timeout means a caller that sends nothing at all
# fails cleanly rather than hanging.
IFS= read -r -t 15 raw || raw="${raw:-}"
key="${raw//[[:space:]]/}"

[[ -n $key ]] || fail "No key given"
[[ ${#key} -ge 16 ]] || fail "That is too short to be an OpenRouter key"
case $key in
  *[![:print:]]*) fail "That contains characters an API key cannot hold" ;;
esac

# Set before the file is created, so it is never briefly world-readable.
umask 077
mkdir -p "$KEY_DIR" 2>/dev/null || fail "Could not create $KEY_DIR"

tmp=$(mktemp "$KEY_DIR/.key.XXXXXX" 2>/dev/null) || fail "Could not write to $KEY_DIR"
if ! {
  printf '# OpenRouter API key for the openrouter bar widget.\n'
  printf '# Saved from the panel. Comments and blank lines are ignored.\n'
  printf '%s\n' "$key"
} > "$tmp"; then
  rm -f "$tmp"
  fail "Could not write the key"
fi

chmod 600 "$tmp" 2>/dev/null
if ! mv -f "$tmp" "$KEY_FILE"; then
  rm -f "$tmp"
  fail "Could not replace $KEY_FILE"
fi

emit --arg path "$KEY_FILE" '{ok: true, path: $path}'
