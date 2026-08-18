#!/usr/bin/env bash
# Ask OpenRouter what credit is left and print one JSON object on stdout.
#
# Key resolution, in order:
#   1. the command passed as $1 (the widget's `keyCommand` setting)
#   2. $OPENROUTER_API_KEY, then $OPENROUTER_KEY
#   3. ~/.config/omarchy/openrouter/key, then ~/.config/openrouter/key
#
# Three endpoints, because they answer different questions and take different
# keys. /credits is the account ledger (purchased and spent); /key is what any
# inference key can see about itself — its cap, if it has one, and its spend;
# /activity is the account-wide spend by day for the last 30 UTC days, and
# only a management (provisioning) key may read it. Whichever answers, answers.
#
# /activity, by design, never includes the current UTC day (OpenRouter 400s if
# you ask it to) — a day only appears once it is "completed". So today's spend
# comes from a local baseline instead: the first poll of each UTC day records
# the account's total_usage from /credits, and every later poll that day
# subtracts that baseline from the live total_usage. Week/month add today's
# live figure on top of whatever /activity has already settled for the days
# before it, so they are not silently short by whatever was spent today.
#
# Always exits 0 with JSON so the panel has something to render when a fetch
# fails. The key reaches curl through a --config file on stdin rather than
# argv, so it never shows up in `ps`.

set -uo pipefail

readonly KEY_COMMAND="${1:-}"
readonly CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
readonly STATE_DIR="$CONFIG_HOME/omarchy/openrouter"
readonly TODAY_FILE="$STATE_DIR/today-spend.json"
# Overridable so the JSON merge below can be exercised against a fixture
# server without reaching the real API.
readonly API="${OPENROUTER_API_BASE:-https://openrouter.ai/api/v1}"

emit() {
  jq -n "$@"
  exit 0
}

fail() {
  emit --arg error "$1" --arg hint "${2:-}" --arg keySource "${KEY_SOURCE:-}" \
    '{ok: false, source: "none", error: $error, hint: $hint, keySource: $keySource}'
}

# First line of a key file that is neither blank nor a comment.
key_from_file() {
  sed -e 's/[[:space:]]*#.*$//' -e 's/[[:space:]]//g' "$1" 2>/dev/null | grep -m1 . || true
}

# Sets KEY and KEY_SOURCE. Not a command substitution on purpose: the caller
# needs both, and the panel shows the source so that a key saved to the file
# while an environment variable is set does not look like it was ignored at
# random.
KEY=""
KEY_SOURCE=""

resolve_key() {
  local candidate file
  if [[ -n $KEY_COMMAND ]]; then
    candidate=$(bash -lc "$KEY_COMMAND" 2>/dev/null | grep -m1 . || true)
    KEY="${candidate//[[:space:]]/}"
    KEY_SOURCE="keyCommand"
    return
  fi
  if [[ -n ${OPENROUTER_API_KEY:-} ]]; then
    KEY="${OPENROUTER_API_KEY//[[:space:]]/}"
    KEY_SOURCE="OPENROUTER_API_KEY"
    return
  fi
  if [[ -n ${OPENROUTER_KEY:-} ]]; then
    KEY="${OPENROUTER_KEY//[[:space:]]/}"
    KEY_SOURCE="OPENROUTER_KEY"
    return
  fi
  for file in "$CONFIG_HOME/omarchy/openrouter/key" "$CONFIG_HOME/openrouter/key"; do
    [[ -r $file ]] || continue
    candidate=$(key_from_file "$file")
    if [[ -n $candidate ]]; then
      KEY="$candidate"
      KEY_SOURCE="$file"
      return
    fi
  done
}

command -v curl >/dev/null 2>&1 || fail "curl is not installed" "Install curl: omarchy pkg add curl"
command -v jq >/dev/null 2>&1 || { printf '{"ok":false,"source":"none","error":"jq is not installed","hint":"Install jq: omarchy pkg add jq"}\n'; exit 0; }

resolve_key
if [[ -z $KEY ]]; then
  if [[ -n $KEY_COMMAND ]]; then
    fail "The keyCommand produced no key" "Check that this prints the key on stdout: $KEY_COMMAND"
  fi
  fail "No OpenRouter API key found" "Paste it below, export OPENROUTER_API_KEY, or point the keyCommand setting at your secret manager."
fi

HTTP_STATUS=""
HTTP_BODY=""

fetch() {
  local raw
  raw=$(
    printf 'silent\nshow-error\nmax-time = 12\nretry = 1\nuser-agent = "omarchy-openrouter/1.0"\nheader = "Authorization: Bearer %s"\nurl = "%s"\n' \
      "$KEY" "$1" | curl --config - --write-out $'\n%{http_code}' 2>/dev/null
  ) || true
  HTTP_STATUS="${raw##*$'\n'}"
  HTTP_BODY="${raw%$'\n'*}"
  if [[ ! $HTTP_STATUS =~ ^[0-9]{3}$ ]]; then
    HTTP_STATUS="000"
    HTTP_BODY=""
  fi
}

# OpenRouter's own message when it has one, a readable stand-in when it does not.
error_of() {
  local body=$1 status=$2 message
  message=$(jq -r 'if type == "object" then (.error.message // .message // empty) else empty end' <<<"$body" 2>/dev/null || true)
  if [[ -n $message ]]; then printf '%s' "$message"; return; fi
  case $status in
    000) printf 'Could not reach openrouter.ai' ;;
    401) printf 'OpenRouter rejected the key' ;;
    403) printf 'This key may not read the account ledger' ;;
    429) printf 'Rate limited by OpenRouter' ;;
    *)   printf 'OpenRouter returned HTTP %s' "$status" ;;
  esac
}

# Sets <name>_json to the body or the literal null, and <name>_error to a
# readable reason. Deliberately not a command substitution: fetch reports
# through globals, and a subshell would throw the status code away.
credits_json=null
credits_error=""
fetch "$API/credits"
if [[ $HTTP_STATUS == 200 ]] && jq -e 'type == "object"' >/dev/null 2>&1 <<<"$HTTP_BODY"; then
  credits_json=$HTTP_BODY
else
  credits_error=$(error_of "$HTTP_BODY" "$HTTP_STATUS")
fi

key_json=null
key_error=""
fetch "$API/key"
if [[ $HTTP_STATUS == 200 ]] && jq -e 'type == "object"' >/dev/null 2>&1 <<<"$HTTP_BODY"; then
  key_json=$HTTP_BODY
else
  key_error=$(error_of "$HTTP_BODY" "$HTTP_STATUS")
fi

# Account-wide, unlike /key's own per-key usage_daily/weekly/monthly, which
# read as zero for any key that was not itself used to place the requests.
# A 403 here just means this key is not a management key; that is a note for
# the panel; it does not fail the whole fetch the way credits+key both
# failing does.
activity_json=null
activity_error=""
fetch "$API/activity"
if [[ $HTTP_STATUS == 200 ]] && jq -e 'type == "object"' >/dev/null 2>&1 <<<"$HTTP_BODY"; then
  activity_json=$HTTP_BODY
else
  activity_error=$(error_of "$HTTP_BODY" "$HTTP_STATUS")
fi

if [[ $credits_json == null && $key_json == null ]]; then
  fail "${key_error:-$credits_error}" "Check the key at openrouter.ai/settings/keys."
fi

# Today's spend, from a local baseline rather than /activity (which cannot
# report on the current UTC day at all). The baseline is the account's
# total_usage as of the first poll of each UTC day; every later poll that day
# is today's spend so far. Best-effort: if the state file can't be read or
# written, today's spend is just unknown for this poll rather than the whole
# fetch failing.
TODAY_UTC="$(date -u +%Y-%m-%d)"
spend_today_json=null

current_total_usage=$(jq -r 'if type == "object" then (.data.total_usage // "null") else "null" end' <<<"$credits_json" 2>/dev/null)
if [[ -n $current_total_usage && $current_total_usage != "null" ]]; then
  baseline_date=""
  baseline_usage=""
  if [[ -r $TODAY_FILE ]]; then
    baseline_date=$(jq -r '.date // ""' "$TODAY_FILE" 2>/dev/null)
    baseline_usage=$(jq -r 'if (.baseline | type) == "number" then .baseline else "" end' "$TODAY_FILE" 2>/dev/null)
  fi
  if [[ $baseline_date != "$TODAY_UTC" || -z $baseline_usage ]]; then
    baseline_usage="$current_total_usage"
    umask 077
    mkdir -p "$STATE_DIR" 2>/dev/null
    tmp=$(mktemp "$STATE_DIR/.today-spend.XXXXXX" 2>/dev/null) || tmp=""
    if [[ -n $tmp ]]; then
      if jq -n --arg date "$TODAY_UTC" --argjson baseline "$baseline_usage" \
           '{date: $date, baseline: $baseline}' > "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$TODAY_FILE" 2>/dev/null || rm -f "$tmp"
      else
        rm -f "$tmp"
      fi
    fi
  fi
  spend_today_json=$(jq -n --argjson now "$current_total_usage" --argjson base "$baseline_usage" \
    '[$now - $base, 0] | max')
fi

jq -n \
  --argjson credits "$credits_json" \
  --argjson keyinfo "$key_json" \
  --argjson activity "$activity_json" \
  --argjson spendToday "$spend_today_json" \
  --arg accountError "$credits_error" \
  --arg keyError "$key_error" \
  --arg activityError "$activity_error" \
  --arg keySource "$KEY_SOURCE" \
  --arg fetchedAt "$(date +%s)" \
  --arg weekStart "$(date -u -d "-$(( $(date -u +%u) - 1 )) days" +%Y-%m-%d)" \
  --arg monthPrefix "$(date -u +%Y-%m)" '
  def num: if type == "number" then . else null end;

  ($credits | if type == "object" then .data else null end) as $c |
  ($keyinfo | if type == "object" then .data else null end) as $k |
  ($activity | if type == "object" then .data else null end) as $a |
  # Sums over whatever days /activity has already settled — never today, by
  # that endpoint'"'"'s own rule — keyed off the date part of a "YYYY-MM-DD
  # HH:MM:SS" string.
  ($a | if . == null then null else (map(select(.date[0:10] >= $weekStart) | .usage) | add // 0) end) as $weekSettled |
  ($a | if . == null then null else (map(select(.date[0:10] | startswith($monthPrefix)) | .usage) | add // 0) end) as $monthSettled |
  {
    ok: true,
    error: "",
    accountError: $accountError,
    keyError: $keyError,
    activityError: $activityError,
    keySource: $keySource,
    fetchedAt: ($fetchedAt | tonumber),

    funded: ($c.total_credits | num),
    spent: ($c.total_usage | num),

    keyLabel: ($k.label // "" | tostring),
    keyLimit: ($k.limit | num),
    keyLimitRemaining: ($k.limit_remaining | num),
    keyLimitReset: ($k.limit_reset // "" | tostring),
    keyUsage: ($k.usage | num),
    freeTier: ($k.is_free_tier == true),

    # Null (not zero) means unknown, so the panel can tell "nothing spent"
    # from "could not ask" — spendToday needs /credits; week/month need
    # /activity too, on top of that, since they add spendToday to whatever
    # /activity has already settled for the earlier days in the window.
    spendToday: $spendToday,
    usageWeekly: (if $weekSettled == null then null
                  elif ($spendToday | type) == "number" then $weekSettled + $spendToday
                  else $weekSettled end),
    usageMonthly: (if $monthSettled == null then null
                   elif ($spendToday | type) == "number" then $monthSettled + $spendToday
                   else $monthSettled end)
  }
  # The headline figure: the account ledger when the key can read it, the
  # key own cap when it cannot, and nothing to promise when neither exists.
  | .remaining = (
      if .funded != null and .spent != null then .funded - .spent
      elif .keyLimitRemaining != null then .keyLimitRemaining
      else null end)
  | .source = (
      if .funded != null and .spent != null then "account"
      elif .keyLimitRemaining != null then "key"
      elif .keyUsage != null then "usage"
      else "none" end)
'
