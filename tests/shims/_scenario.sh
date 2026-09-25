# shellcheck shell=bash

FAKE_SHIM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAKE_FIXTURES="${FAKE_FIXTURES:-$(cd "$FAKE_SHIM_DIR/../fixtures" && pwd)}"

fake_record() {
  local line="$*"
  printf '%s\n' "${line//$'\n'/ }" >>"${FAKE_CALLS:-/dev/null}"
}

# A tripwire line fails the oracle-a1 suite in teardown: the shim saw run.sh do something unsafe.
fake_trip() {
  printf '!! %s\n' "$*" >>"${FAKE_CALLS:-/dev/null}"
}

fake_die() {
  printf 'fake %s: %s\n' "${FAKE_TOOL:-shim}" "$*" >&2
  exit 97
}

fake_default() {
  [[ -n "${!1+set}" ]] || printf -v "$1" '%s' "$2"
}

# Usage: fake_lookup SPEC KEY... ; SPEC is "KEY=VALUE ... [*=VALUE | VALUE]", first matching KEY wins.
fake_lookup() {
  local spec="$1" entry key fallback="" have_fallback=false
  local -a entries=()
  shift
  read -r -a entries <<<"$spec"
  for key in "$@"; do
    for entry in "${entries[@]}"; do
      if [[ "$entry" == *=* && "${entry%=*}" == "$key" ]]; then
        printf '%s' "${entry##*=}"
        return 0
      fi
    done
  done
  for entry in "${entries[@]}"; do
    if [[ "$entry" != *=* ]]; then
      printf '%s' "$entry"
      return 0
    elif [[ "${entry%=*}" == "*" ]]; then
      fallback="${entry##*=}"
      have_fallback=true
    fi
  done
  "$have_fallback" || return 1
  printf '%s' "$fallback"
}

fake_fixture_path() {
  local name="$1" dir="${2:-$FAKE_FIXTURES}"
  if [[ "$name" == /* && -f "$name" ]]; then
    printf '%s' "$name"
  elif [[ -f "$dir/$name" ]]; then
    printf '%s' "$dir/$name"
  elif [[ -f "$dir/$name.log" ]]; then
    printf '%s' "$dir/$name.log"
  else
    return 1
  fi
}

fake_is_error_fixture() {
  [[ "$1" == /* && -f "$1" ]] || [[ -f "$FAKE_FIXTURES/$1.log" ]]
}

fake_emit_error() {
  local path
  path="$(fake_fixture_path "$1")" || fake_die "no error fixture named '$1'"
  cat "$path" >&2
}

fake_load_scenario() {
  case "${FAKE_SCENARIO:-happy}" in
    happy) ;;
    report_no_capacity) fake_default FAKE_CAPACITY OUT_OF_HOST_CAPACITY ;;
    report_error) fake_default FAKE_CAPACITY cli-capacity-error ;;
    report_empty) fake_default FAKE_CAPACITY empty ;;
    apply_capacity) fake_default FAKE_APPLY '*=capacity' ;;
    second_ad)
      fake_default FAKE_ADS 'AD-1 AD-2'
      fake_default FAKE_APPLY 'AD-1=capacity AD-2=ok'
      ;;
    fault_domains) fake_default FAKE_APPLY 'AD-1/FAULT-DOMAIN-2=ok *=capacity' ;;
    limit) fake_default FAKE_APPLY '*=limit' ;;
    throttle) fake_default FAKE_APPLY '*=throttle' ;;
    lock) fake_default FAKE_APPLY '*=lock' ;;
    unknown_error) fake_default FAKE_APPLY '*=other' ;;
    async_capacity) fake_default FAKE_APPLY '*=async:workrequest-capacity' ;;
    auth_probe) fake_default FAKE_AD_LIST cli-auth ;;
    ad_throttle) fake_default FAKE_AD_LIST cli-throttle ;;
    orphan) fake_default FAKE_INSTANCE_LIST instances-orphan.json ;;
    orphan_terminating) fake_default FAKE_INSTANCE_LIST instances-terminating.json ;;
    in_state_no_changes)
      fake_default FAKE_STATE state-running.json
      fake_default FAKE_PLAN_JSON plan-no-changes.json
      ;;
    in_state_replace)
      fake_default FAKE_STATE state-running.json
      fake_default FAKE_PLAN_JSON plan-replace.json
      ;;
    in_state_update)
      fake_default FAKE_STATE state-running.json
      fake_default FAKE_PLAN_JSON plan-update.json
      ;;
    in_state_output_only)
      fake_default FAKE_STATE state-running.json
      fake_default FAKE_PLAN_JSON plan-output-only.json
      ;;
    dropped_on_refresh)
      fake_default FAKE_STATE state-running.json
      fake_default FAKE_PLAN_JSON plan-dropped.json
      fake_default FAKE_REFRESH_DROPS_A1 true
      fake_default FAKE_INSTANCE_LIST instances-terminated.json
      ;;
    terminated_in_state)
      fake_default FAKE_STATE state-terminated.json
      fake_default FAKE_PLAN_JSON plan-terminated.json
      fake_default FAKE_INSTANCE_LIST instances-terminated.json
      ;;
    tainted_terminated)
      fake_default FAKE_STATE state-tainted-terminated.json
      fake_default FAKE_PLAN_JSON plan-tainted-terminated.json
      fake_default FAKE_INSTANCE_LIST instances-terminated.json
      ;;
    terminating)
      fake_default FAKE_STATE state-terminating.json
      fake_default FAKE_PLAN_JSON plan-terminating.json
      ;;
    tainted_running)
      fake_default FAKE_STATE state-tainted-running.json
      fake_default FAKE_PLAN_JSON plan-tainted-running.json
      ;;
    reconcile_lock)
      fake_default FAKE_STATE state-running.json
      fake_default FAKE_PLAN_LOG lock
      ;;
    *)
      printf 'fake %s: unknown FAKE_SCENARIO %s\n' "${FAKE_TOOL:-shim}" "$FAKE_SCENARIO" >&2
      exit 98
      ;;
  esac
  fake_default FAKE_ADS 'AD-1'
  fake_default FAKE_AD_LIST ok
  fake_default FAKE_CAPACITY AVAILABLE
  fake_default FAKE_INSTANCE_LIST none
  fake_default FAKE_TF_INIT ok
  fake_default FAKE_TF_VALIDATE ok
  fake_default FAKE_STATE state-empty.json
  fake_default FAKE_SHOW_STATE ok
  fake_default FAKE_PLAN_JSON plan-no-changes.json
  fake_default FAKE_PLAN_LOG ''
  fake_default FAKE_PLAN_EXIT ''
  fake_default FAKE_PLAN_APPLY ok
  fake_default FAKE_APPLY '*=ok'
  fake_default FAKE_STATE_RM ok
  fake_default FAKE_OUTPUT ok
  fake_default FAKE_REFRESH_DROPS_A1 false
  fake_default FAKE_ASSIGNED_FD FAULT-DOMAIN-1
  fake_default FAKE_PUBLIC_IP 203.0.113.25
  fake_default FAKE_INSTANCE_ID ocid1.instance.oc1.ap-sydney-1.anzxsljrcreateda1w3e5r7t9y1u3i5o7p9a1s3d5f7g9
}
