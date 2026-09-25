# shellcheck shell=bash
# shellcheck disable=SC2034 # consumed by the .bats files that load this helper

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
SHIMS="$REPO_ROOT/tests/shims"
FIXTURES="$REPO_ROOT/tests/fixtures"
RUN_SH="$REPO_ROOT/modules/oracle-a1/run.sh"
COMMON_SH="$REPO_ROOT/lib/common.sh"
CLASSIFY_SH="$REPO_ROOT/modules/oracle-a1/lib/classify.sh"
TF_MODULE_DIR="$REPO_ROOT/modules/oracle-a1/terraform"

TEST_TENANCY="ocid1.tenancy.oc1..aaaaaaaasecrettenancyvalue7x3k9q2m5zw8"
TEST_SSH_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAISecretTestKeyDoNotLeak0123456789 tester@example"
TEST_NAMESPACE="secretnsq9z8x7"
TEST_BUCKET="freebie-hub-tfstate"

CALL_AD_LIST='^oci iam availability-domain list'
CALL_CAPACITY='^oci compute compute-capacity-report create'
CALL_INSTANCES='^oci compute instance list'
CALL_TF='^terraform '
CALL_INIT='^terraform [^ ]+ init( |$)'
CALL_SHOW_STATE='^terraform [^ ]+ show -json -no-color$'
CALL_PLAN='^terraform [^ ]+ plan( |$)'
CALL_APPLY='^terraform [^ ]+ apply( |$)'
CALL_APPLY_CREATE='^terraform [^ ]+ apply .*-auto-approve'
CALL_APPLY_SAVED='^terraform [^ ]+ apply .*reconcile\.tfplan$'
CALL_STATE_RM='^terraform [^ ]+ state rm .*oci_core_instance\.a1$'
CALL_OUTPUT='^terraform [^ ]+ output -json'

reset_outputs() {
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/github_output"
  export GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/step_summary"
  : >"$GITHUB_OUTPUT"
  : >"$GITHUB_STEP_SUMMARY"
}

setup_module_env() {
  local name
  while IFS= read -r name; do
    unset "$name"
  done < <(compgen -v FAKE_; compgen -v TF_VAR_)
  unset GITHUB_ACTIONS OCI_CLI_CONFIG_FILE OCI_REGION OCPUS MEMORY_GB CAPACITY_CHECK TRY_FAULT_DOMAINS \
    MAX_RUN_SECONDS LOCK_TIMEOUT SUPPRESS_LABEL_WARNING TF_IN_AUTOMATION TF_INPUT TF_CLI_ARGS

  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/.oci"
  : >"$HOME/.oci/config"

  export FAKE_CALLS="$BATS_TEST_TMPDIR/calls"
  export FAKE_STATE_DIR="$BATS_TEST_TMPDIR/fake-state"
  export RUNNER_TEMP="$BATS_TEST_TMPDIR/runner"
  : >"$FAKE_CALLS"
  mkdir -p "$FAKE_STATE_DIR" "$RUNNER_TEMP"

  export PATH="$SHIMS:$PATH"
  export TENANCY_OCID="$TEST_TENANCY"
  export OCI_STATE_BUCKET="$TEST_BUCKET"
  export OCI_STATE_NAMESPACE="$TEST_NAMESPACE"
  export TF_VAR_ssh_public_key="$TEST_SSH_KEY"
  export SLEEP_BETWEEN=0
  export TF_DIR="$TF_MODULE_DIR"
  reset_outputs
}

new_run() {
  : >"$FAKE_CALLS"
  reset_outputs
}

run_module() {
  run --separate-stderr "$RUN_SH"
}

gh_output() {
  local key="$1" file="${2:-$GITHUB_OUTPUT}"
  awk -v key="$key" '
    delim != "" {
      if ($0 == delim) {
        if (name == key) { value = buf; found = 1 }
        delim = ""
        next
      }
      buf = nlines++ ? buf "\n" $0 : $0
      next
    }
    {
      i = index($0, "<<")
      if (i > 1) { name = substr($0, 1, i - 1); delim = substr($0, i + 2); buf = ""; nlines = 0; next }
      i = index($0, "=")
      if (i > 1 && substr($0, 1, i - 1) == key) { value = substr($0, i + 1); found = 1 }
    }
    END { if (found) printf "%s", value; exit(found ? 0 : 1) }' "$file"
}

gh_output_wellformed() {
  awk '
    delim != "" { if ($0 == delim) delim = ""; next }
    /^[A-Za-z_][A-Za-z0-9_-]*<<ghadelimiter_[0-9a-f]+$/ { delim = substr($0, index($0, "<<") + 2); next }
    { bad = 1; print "unexpected line: " $0 > "/dev/stderr" }
    END { if (delim != "") { print "unterminated block" > "/dev/stderr"; bad = 1 } exit bad }' "${1:-$GITHUB_OUTPUT}"
}

dump_context() {
  {
    printf -- '--- exit status: %s\n' "${status:-?}"
    printf -- '--- stdout:\n%s\n' "${output:-}"
    printf -- '--- stderr:\n%s\n' "${stderr:-}"
    printf -- '--- calls:\n'
    cat "$FAKE_CALLS" 2>/dev/null
    printf -- '--- GITHUB_OUTPUT:\n'
    cat "${GITHUB_OUTPUT:-/dev/null}" 2>/dev/null
    printf -- '--- step summary:\n'
    cat "${GITHUB_STEP_SUMMARY:-/dev/null}" 2>/dev/null
  } >&2
}

fail_with() {
  printf 'FAILED: %s\n' "$*" >&2
  dump_context
  return 1
}

assert_result() {
  local want_rc="$1" want_status="$2" want_reason="$3" got_status got_reason
  got_status="$(gh_output status)"
  got_reason="$(gh_output reason)"
  if [[ "$status" != "$want_rc" || "$got_status" != "$want_status" || "$got_reason" != "$want_reason" ]]; then
    fail_with "want rc=$want_rc status=$want_status reason=$want_reason; got rc=$status status=$got_status reason=$got_reason"
    return 1
  fi
  gh_output_wellformed || fail_with "GITHUB_OUTPUT is not in the heredoc format"
}

assert_output_value() {
  local got
  got="$(gh_output "$1")" || {
    fail_with "output '$1' was not emitted"
    return 1
  }
  [[ "$got" == "$2" ]] || fail_with "output '$1': want '$2', got '$got'"
}

call_count() {
  grep -cE -- "$1" "$FAKE_CALLS" || true
}

assert_called() {
  grep -qE -- "$1" "$FAKE_CALLS" || fail_with "expected a call matching: $1"
}

refute_called() {
  if grep -qE -- "$1" "$FAKE_CALLS"; then
    fail_with "expected no call matching: $1"
    return 1
  fi
}

assert_call_count() {
  local got
  got="$(call_count "$1")"
  [[ "$got" == "$2" ]] || fail_with "expected $2 call(s) matching '$1', got $got"
}

first_call_line() {
  grep -nE -- "$1" "$FAKE_CALLS" | head -n1 | cut -d: -f1
}

assert_call_order() {
  local a b
  a="$(first_call_line "$1")"
  b="$(first_call_line "$2")"
  if [[ -z "$a" || -z "$b" ]] || ((a >= b)); then
    fail_with "expected a call matching '$1' before one matching '$2'"
    return 1
  fi
}

refute_tripwire() {
  if grep -q '^!! ' "$FAKE_CALLS" 2>/dev/null; then
    fail_with "a shim tripwire fired: $(grep '^!! ' "$FAKE_CALLS")"
    return 1
  fi
}

summary_text() {
  cat "$GITHUB_STEP_SUMMARY"
}

assert_contains() {
  [[ "$1" == *"$2"* ]] || fail_with "expected to find '$2'"
}

refute_contains() {
  if [[ "$1" == *"$2"* ]]; then
    fail_with "did not expect to find '$2'"
    return 1
  fi
}

assert_summary_contains() {
  assert_contains "$(summary_text)" "$1"
}

refute_summary_contains() {
  refute_contains "$(summary_text)" "$1"
}

assert_no_secret_leak() {
  local where secret
  for secret in "$TEST_TENANCY" "$TEST_SSH_KEY" "$TEST_NAMESPACE" "${TF_VAR_compartment_ocid:-}" "$@"; do
    [[ -n "$secret" ]] || continue
    for where in stdout stderr summary github_output; do
      case "$where" in
        stdout) refute_contains "${output:-}" "$secret" || return 1 ;;
        stderr) refute_contains "${stderr:-}" "$secret" || return 1 ;;
        summary) refute_contains "$(summary_text)" "$secret" || return 1 ;;
        github_output) refute_contains "$(cat "$GITHUB_OUTPUT")" "$secret" || return 1 ;;
      esac
    done
  done
}
