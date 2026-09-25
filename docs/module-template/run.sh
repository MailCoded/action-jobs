#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HUB_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../lib/common.sh
source "$HUB_ROOT/lib/common.sh"

readonly MODULE="example"

EXAMPLE_TARGET="${EXAMPLE_TARGET:-}"

# Usage: conclude STATUS REASON MESSAGE [GUIDANCE_MARKDOWN]
# STATUS: done=0 goal reached | fatal=1 human must act | retry=2 next tick retries | skipped=3 nothing to do
conclude() {
  local status="$1" reason="$2" message="$3" guidance="${4:-}"
  summary_line "## ${MODULE}: ${status} (${reason})"
  summary_line ""
  summary_line "$message"
  if [[ -n "$guidance" ]]; then
    summary_line ""
    summary_line "$guidance"
  fi
  summary_line ""
  finish "$status" "$reason" "$message"
}

preflight() {
  local missing names
  if ! missing="$(require_env EXAMPLE_TARGET)"; then
    names="$(tr '\n' ' ' <<<"$missing")"
    conclude fatal missing_config "Missing required settings: ${names% }" \
      "Add them under **Settings → Secrets and variables → Actions**. Values are never printed."
  fi
}

check_target() {
  [[ "$1" != "unreachable" ]]
}

main() {
  preflight
  log "Checking ${EXAMPLE_TARGET}..."
  if check_target "$EXAMPLE_TARGET"; then
    emit target "$EXAMPLE_TARGET"
    conclude "done" checked "Checked ${EXAMPLE_TARGET}."
  fi
  conclude retry unavailable "${EXAMPLE_TARGET} did not answer; the next scheduled run tries again."
}

main "$@"
