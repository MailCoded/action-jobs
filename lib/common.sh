# shellcheck shell=bash

[[ -n "${_HUB_COMMON_LOADED:-}" ]] && return 0
_HUB_COMMON_LOADED=1

readonly EXIT_DONE=0
readonly EXIT_FATAL=1
readonly EXIT_RETRY=2
readonly EXIT_SKIPPED=3

in_actions() {
  [[ "${GITHUB_ACTIONS:-}" == "true" ]]
}

log() {
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2
}

_gh_escape() {
  local s="$1"
  s="${s//'%'/%25}"
  s="${s//$'\r'/%0D}"
  s="${s//$'\n'/%0A}"
  printf '%s' "$s"
}

annotate() {
  local level="$1" message="$2"
  in_actions || return 0
  printf '::%s::%s\n' "$level" "$(_gh_escape "$message")"
}

warn() {
  log "WARNING: $*"
  annotate warning "$*"
}

require_env() {
  local name missing=()
  for name in "$@"; do
    [[ -n "${!name:-}" ]] || missing+=("$name")
  done
  ((${#missing[@]} == 0)) && return 0
  printf '%s\n' "${missing[@]}"
  return 1
}

mask() {
  local line
  in_actions || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ -n "${line//[[:space:]]/}" ]]; then
      printf '::add-mask::%s\n' "$(_gh_escape "$line")"
    fi
  done <<<"$1"
  return 0
}

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

_random_hex() {
  local hex
  hex="$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
  printf '%s' "${hex:-${RANDOM}${RANDOM}${RANDOM}${RANDOM}$$}"
}

emit() {
  local key="$1" value="${2-}" delim
  if [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]]; then
    log "emit: invalid output name '$key'"
    return 1
  fi
  delim="ghadelimiter_$(_random_hex)"
  printf '%s<<%s\n%s\n%s\n' "$key" "$delim" "$value" "$delim" >>"${GITHUB_OUTPUT:-/dev/null}"
}

summary_line() {
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    printf '%s\n' "$*" >>"$GITHUB_STEP_SUMMARY"
  else
    printf '%s\n' "$*"
  fi
}

_md_cell() {
  local s="$1"
  s="${s//$'\r'/}"
  s="${s//$'\n'/ }"
  s="${s//|/\\|}"
  printf '%s' "$s"
}

# Usage: summary_table NCOLS HEADER... CELL...
summary_table() {
  local ncols="$1" i=0 row="|" sep="|" cell
  shift
  if [[ ! "$ncols" =~ ^[1-9][0-9]*$ ]] || (($# < ncols)); then
    log "summary_table: need NCOLS and at least NCOLS headers"
    return 1
  fi
  for cell in "$@"; do
    row+=" $(_md_cell "$cell") |"
    if ((i < ncols)); then
      sep+="---|"
    fi
    i=$((i + 1))
    if ((i % ncols == 0)); then
      summary_line "$row"
      if ((i == ncols)); then
        summary_line "$sep"
      fi
      row="|"
    fi
  done
  if [[ "$row" != "|" ]]; then
    summary_line "$row"
  fi
}

# Usage: summary_details TITLE FILE [MAX_LINES]
summary_details() {
  local title="$1" file="$2" max="${3:-60}" esc=$'\033'
  [[ -s "$file" ]] || return 0
  summary_line "<details><summary>$(_md_cell "$title")</summary>"
  summary_line ""
  summary_line '```text'
  # shellcheck disable=SC2016
  summary_line "$(tail -n "$max" "$file" | sed -e "s/${esc}\[[0-9;]*[A-Za-z]//g" -e 's/```/` ` `/g')"
  summary_line '```'
  summary_line ""
  summary_line "</details>"
}

status_exit_code() {
  case "$1" in
    done) printf '%s' "$EXIT_DONE" ;;
    fatal) printf '%s' "$EXIT_FATAL" ;;
    retry) printf '%s' "$EXIT_RETRY" ;;
    skipped) printf '%s' "$EXIT_SKIPPED" ;;
    *) return 1 ;;
  esac
}

finish() {
  local status="$1" reason="$2" message="$3" code
  if ! code="$(status_exit_code "$status")"; then
    log "finish: unknown status '$status', treating as fatal"
    status=fatal
    code="$EXIT_FATAL"
  fi
  emit status "$status"
  emit reason "$reason"
  emit message "$message"
  case "$status" in
    fatal) annotate error "$message" ;;
    retry) annotate warning "$message" ;;
    *) annotate notice "$message" ;;
  esac
  log "$status ($reason): $message"
  exit "$code"
}
