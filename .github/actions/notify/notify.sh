#!/usr/bin/env bash
set -uo pipefail
# A notification problem must never fail the calling job, whatever goes wrong below.
trap 'exit 0' EXIT

APPRISE_VERSION="${APPRISE_VERSION:-1.13.1}"

warn() {
  printf '::warning::%s\n' "$1"
}

in_actions() {
  [[ "${GITHUB_ACTIONS:-}" == "true" ]]
}

gh_escape() {
  local s="$1"
  s="${s//'%'/%25}"
  s="${s//$'\r'/%0D}"
  s="${s//$'\n'/%0A}"
  printf '%s' "$s"
}

trim() {
  local s="${1//$'\r'/}"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

with_timeout() {
  local seconds="$1"
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$seconds" "$@"
  else
    "$@"
  fi
}

mask_urls() {
  local url parts=()
  in_actions || return 0
  IFS=$' \t\r\n' read -r -d '' -a parts <<<"${1//,/ }"
  for url in "${parts[@]}"; do
    [[ -n "$url" ]] && printf '::add-mask::%s\n' "$(gh_escape "$url")"
  done
  return 0
}

notification_type() {
  case "$1" in
    done) printf 'success' ;;
    fatal | failed | failure) printf 'failure' ;;
    *) printf 'info' ;;
  esac
}

run_url() {
  if [[ -n "${GITHUB_SERVER_URL:-}" && -n "${GITHUB_REPOSITORY:-}" && -n "${GITHUB_RUN_ID:-}" ]]; then
    printf '%s/%s/actions/runs/%s' "$GITHUB_SERVER_URL" "$GITHUB_REPOSITORY" "$GITHUB_RUN_ID"
  fi
}

build_title() {
  local title status="$1"
  title="$(trim "${NOTIFY_TITLE:-}")"
  if [[ -z "$title" ]]; then
    title="${GITHUB_WORKFLOW:-freebie-hub}: ${status:-notification}"
  fi
  printf '%s' "$title"
}

build_body() {
  local title="$1" body url
  body="$(trim "${NOTIFY_BODY:-}")"
  url="$(run_url)"
  if [[ -z "$body" ]]; then
    body="${title}. No details were reported; the job probably failed before the module finished."
  fi
  if [[ -n "$url" && "$body" != *"$url"* ]]; then
    body+=$'\n\n'"Run: ${url}"
  fi
  printf '%s' "$body"
}

pipx_version_of() {
  pipx list --short 2>/dev/null | awk -v pkg="$1" '$1 == pkg { print $2; exit }'
}

install_apprise() {
  local installed bin_dir args=(install)
  if command -v pipx >/dev/null 2>&1; then
    installed="$(pipx_version_of apprise)"
    if [[ "$installed" != "$APPRISE_VERSION" ]]; then
      [[ -z "$installed" ]] || args+=(--force)
      with_timeout 180 pipx "${args[@]}" "apprise==${APPRISE_VERSION}" </dev/null || return 1
    fi
    bin_dir="$(pipx environment --value PIPX_BIN_DIR 2>/dev/null)"
  else
    command -v python3 >/dev/null 2>&1 || return 1
    with_timeout 180 python3 -m pip install --user --disable-pip-version-check --quiet "apprise==${APPRISE_VERSION}" </dev/null || return 1
    bin_dir="$(python3 -m site --user-base 2>/dev/null)/bin"
  fi
  if [[ -n "$bin_dir" && -d "$bin_dir" ]]; then
    PATH="$bin_dir:$PATH"
  fi
  command -v apprise >/dev/null 2>&1
}

main() {
  local urls="${APPRISE_URLS:-}" status type title body rc
  if [[ -z "${urls//[[:space:],]/}" ]]; then
    printf 'notify: APPRISE_URLS is empty; no notification sent.\n'
    return 0
  fi
  mask_urls "$urls"

  status="$(trim "${NOTIFY_STATUS:-}")"
  type="$(notification_type "$status")"
  title="$(build_title "$status")"
  body="$(build_body "$title")"

  if ! install_apprise; then
    warn "Could not install apprise ${APPRISE_VERSION}; notification not sent."
    return 0
  fi

  export APPRISE_URLS="$urls"
  # Apprise logs bare targets (ntfy topics, recipients) at WARNING/INFO, which no mask covers.
  with_timeout 120 apprise -n "$type" -t "$title" -b "$body" </dev/null
  rc=$?
  if ((rc == 124)); then
    warn "Notification timed out after 120s (apprise)."
  elif ((rc != 0)); then
    warn "Notification failed (apprise exit ${rc}). Check the APPRISE_URLS secret."
  else
    printf 'notify: sent "%s" (%s).\n' "$title" "$type"
  fi
  return 0
}

main
exit 0
