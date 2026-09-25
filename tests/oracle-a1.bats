#!/usr/bin/env bats
# shellcheck shell=bats

bats_require_minimum_version 1.5.0

load helpers

LOCK_ID="c0a8f6d2-5b7e-4f3a-9d21-7e4b8a6c1f90"
CREATED_ID="ocid1.instance.oc1.ap-sydney-1.anzxsljrcreateda1w3e5r7t9y1u3i5o7p9a1s3d5f7g9"
FIXTURE_INSTANCE_ID="ocid1.instance.oc1.ap-sydney-1.anzxsljrfixturea1q7m3x8c2b5n9k4j1h6g0f3d8s2a7"
ORPHAN_ID="ocid1.instance.oc1.ap-sydney-1.anzxsljrorphana1r5t7y9u1i3o5p7a9s1d3f5g7h9j1k3"

setup() {
  setup_module_env
}

teardown() {
  refute_tripwire
}

plan_fixture_query() {
  jq -r "$2" "$FIXTURES/terraform/$1"
}

# ------------------------------------------------------------------ create path and outcomes

@test "A: report AVAILABLE and apply ok => done with every output populated" {
  export FAKE_SCENARIO=happy
  run_module
  assert_result 0 "done" instance_created
  assert_output_value public_ip 203.0.113.25
  assert_output_value instance_id "$CREATED_ID"
  assert_output_value availability_domain AD-1
  assert_output_value fault_domain FAULT-DOMAIN-1
  assert_output_value image_name Canonical-Ubuntu-24.04-aarch64-2026.09.18-0
  assert_output_value ocpus 2
  assert_output_value memory_in_gbs 12
  assert_output_value ssh_command "ssh ubuntu@203.0.113.25"
  assert_contains "$(gh_output message)" "203.0.113.25"
  assert_call_count "$CALL_APPLY" 1
  assert_call_count "$CALL_CAPACITY" 1
  assert_called "$CALL_CAPACITY --region ap-sydney-1 --availability-domain AD-1 --compartment-id $TEST_TENANCY "
  assert_call_order "$CALL_AD_LIST" "$CALL_INIT"
  assert_call_order "$CALL_INIT" "$CALL_SHOW_STATE"
  assert_call_order "$CALL_INSTANCES" "$CALL_CAPACITY"
  assert_call_order "$CALL_CAPACITY" "$CALL_APPLY_CREATE"
  assert_call_order "$CALL_APPLY_CREATE" "$CALL_OUTPUT"
  refute_called "$CALL_PLAN"
}

@test "A: init uses the backend settings, a read-only lock file and -no-color everywhere" {
  local marker="$BATS_TEST_TMPDIR/marker" changed
  : >"$marker"
  sleep 1
  run_module
  changed="$(find "$TF_MODULE_DIR" \( -name .terraform -o -name .claude \) -prune -o -newer "$marker" -print)"
  [ -z "$changed" ] || fail_with "the run wrote into TF_DIR: $changed"
  assert_result 0 "done" instance_created
  assert_called "$CALL_INIT.* -lockfile=readonly .*-backend-config=bucket=$TEST_BUCKET -backend-config=namespace=$TEST_NAMESPACE -backend-config=region=ap-sydney-1$"
  assert_called '^terraform [^ ]+ validate -no-color$'
  [ "$(grep -c '^terraform ' "$FAKE_CALLS")" -eq "$(grep -c '^terraform .* -no-color' "$FAKE_CALLS")" ]
  assert_called "$CALL_APPLY_CREATE -lock-timeout=60s -var=instance_availability_domain=AD-1 -var=fault_domain=$"
}

@test "A: the done summary has the property table and the attempts table" {
  run_module
  assert_result 0 "done" instance_created
  assert_summary_contains "## ✅ oracle-a1: done (instance_created)"
  assert_summary_contains "| public_ip | 203.0.113.25 |"
  assert_summary_contains "| AD-1 | any | created |"
}

@test "B: report OUT_OF_HOST_CAPACITY => apply never called, retry no_capacity" {
  export FAKE_SCENARIO=report_no_capacity
  run_module
  assert_result 2 retry no_capacity
  refute_called "$CALL_APPLY"
  assert_call_count "$CALL_CAPACITY" 1
  assert_summary_contains "| AD-1 | any | skipped: capacity report OUT_OF_HOST_CAPACITY |"
}

@test "C: report AVAILABLE but apply hits capacity in the only AD => retry no_capacity" {
  export FAKE_SCENARIO=apply_capacity
  run_module
  assert_result 2 retry no_capacity
  assert_call_count "$CALL_APPLY" 1
  [ "$(call_count "$CALL_SHOW_STATE")" -eq 2 ]
  grep -A1 -E "$CALL_APPLY_CREATE" "$FAKE_CALLS" | tail -n1 | grep -qE "$CALL_SHOW_STATE"
  assert_summary_contains "| AD-1 | any | out of host capacity |"
  assert_summary_contains "500-InternalError, Out of host capacity."
}

@test "D: two ADs, AD-1 capacity error and AD-2 ok => done in AD-2" {
  export FAKE_SCENARIO=second_ad
  run_module
  assert_result 0 "done" instance_created
  assert_output_value availability_domain AD-2
  assert_call_count "$CALL_APPLY" 2
  assert_call_order "$CALL_APPLY_CREATE.*instance_availability_domain=AD-1 " "$CALL_APPLY_CREATE.*instance_availability_domain=AD-2 "
  assert_called "$CALL_CAPACITY .*--availability-domain AD-2 "
  assert_contains "$(gh_output message)" "(AD-2)"
}

@test "E: apply LimitExceeded => fatal limit_exceeded with no further attempts" {
  export FAKE_SCENARIO=limit FAKE_ADS="AD-1 AD-2" TRY_FAULT_DOMAINS=true
  run_module
  assert_result 1 fatal limit_exceeded
  assert_call_count "$CALL_APPLY" 1
  assert_call_count "$CALL_CAPACITY" 1
  assert_summary_contains "### What to fix"
  assert_summary_contains "standard-a1-memory-count"
}

@test "F: AD listing fails with auth => fatal auth and Terraform never runs" {
  export FAKE_SCENARIO=auth_probe
  run_module
  assert_result 1 fatal auth
  refute_called "$CALL_TF"
  assert_summary_contains "API signing key"
  assert_summary_contains '"code": "NotAuthenticated"'
  assert_contains "$stderr" '"status": 401'
}

@test "G: instance in state and plan has no changes => done instance_present, nothing created" {
  export FAKE_SCENARIO=in_state_no_changes
  run_module
  assert_result 0 "done" instance_present
  refute_called "$CALL_APPLY"
  refute_called "$CALL_INSTANCES"
  refute_called "$CALL_CAPACITY"
  assert_called "$CALL_PLAN.*-detailed-exitcode -out=[^ ]*reconcile\\.tfplan -var=instance_availability_domain=AD-1$"
  assert_called '^terraform [^ ]+ show -json -no-color [^ ]*reconcile\.tfplan$'
  assert_output_value public_ip 203.0.113.10
  assert_output_value instance_id "$FIXTURE_INSTANCE_ID"
  assert_output_value fault_domain FAULT-DOMAIN-2
}

@test "H: instance in state and plan wants a replace => fatal refuse_destructive, nothing applied" {
  export FAKE_SCENARIO=in_state_replace
  run_module
  assert_result 1 fatal refuse_destructive
  refute_called "$CALL_APPLY"
  assert_contains "$(gh_output message)" "delete then create oci_core_instance.a1"
  assert_summary_contains '- `oci_core_instance.a1`: delete then create (replace_because_cannot_update)'
  assert_summary_contains '- `oci_core_subnet.public[0]`: delete (delete_because_count_index)'
}

@test "I1: dropped from state on refresh => create path, the reconcile plan is never applied" {
  [ "$(plan_fixture_query plan-dropped.json '[.prior_state.values.root_module.resources[] | select(.address == "oci_core_instance.a1")] | length')" = 0 ]
  [ "$(plan_fixture_query plan-dropped.json '.resource_drift[] | select(.address == "oci_core_instance.a1") | .change.actions | join(",")')" = delete ]
  [ "$(plan_fixture_query plan-dropped.json '.resource_changes[] | select(.address == "oci_core_instance.a1") | .change.actions | join(",")')" = create ]
  export FAKE_SCENARIO=dropped_on_refresh
  run_module
  assert_result 0 "done" instance_created
  refute_called "$CALL_APPLY_SAVED"
  refute_called "$CALL_STATE_RM"
  assert_call_count "$CALL_APPLY" 1
  assert_call_order "$CALL_PLAN" "$CALL_INSTANCES"
  assert_call_order "$CALL_INSTANCES" "$CALL_APPLY_CREATE"
  assert_output_value instance_id "$CREATED_ID"
}

@test "I2: TERMINATED in prior_state => state rm, then the create path" {
  export FAKE_SCENARIO=terminated_in_state
  run_module
  assert_result 0 "done" instance_created
  assert_called "^terraform [^ ]+ state rm -no-color -lock-timeout=60s oci_core_instance\\.a1$"
  assert_call_order "$CALL_STATE_RM" "$CALL_INSTANCES"
  assert_call_order "$CALL_STATE_RM" "$CALL_APPLY_CREATE"
  refute_called "$CALL_APPLY_SAVED"
  assert_call_count "$CALL_APPLY" 1
}

@test "I3: tainted and TERMINATED => state rm, then the create path (never the replace plan)" {
  [ "$(plan_fixture_query plan-tainted-terminated.json '.resource_changes[] | select(.address == "oci_core_instance.a1") | .action_reason')" = replace_because_tainted ]
  export FAKE_SCENARIO=tainted_terminated
  run_module
  assert_result 0 "done" instance_created
  assert_call_order "$CALL_STATE_RM" "$CALL_APPLY_CREATE"
  refute_called "$CALL_APPLY_SAVED"
  assert_call_count "$CALL_APPLY" 1
}

@test "J: an untracked A1 exists => fatal orphan with import instructions" {
  export FAKE_SCENARIO=orphan
  run_module
  assert_result 1 fatal orphan
  refute_called "$CALL_CAPACITY"
  refute_called "$CALL_APPLY"
  assert_summary_contains "$ORPHAN_ID"
  assert_summary_contains "terraform -chdir=modules/oracle-a1/terraform import oci_core_instance.a1 <instance-ocid>"
  assert_summary_contains "import 'oci_core_subnet.public[0]'"
  refute_summary_contains "micro-box"
  refute_summary_contains "anzxsljrdeada1"
}

@test "J: other shapes and TERMINATED A1s are not orphans" {
  export FAKE_INSTANCE_LIST=instances-other-shapes.json
  run_module
  assert_result 0 "done" instance_created
  new_run
  rm -f "$FAKE_STATE_DIR/state.json"
  export FAKE_INSTANCE_LIST=instances-terminated.json
  run_module
  assert_result 0 "done" instance_created
}

@test "J: a STOPPED untracked A1 is an orphan too" {
  jq '.data |= map(select(.shape == "VM.Standard.A1.Flex") | ."lifecycle-state" = "STOPPED") | .data |= .[:1]' \
    "$FIXTURES/oci/instances-orphan.json" >"$BATS_TEST_TMPDIR/stopped.json"
  export FAKE_INSTANCE_LIST="$BATS_TEST_TMPDIR/stopped.json"
  run_module
  assert_result 1 fatal orphan
  assert_summary_contains "STOPPED"
}

@test "K: apply 429 => retry throttled and stop immediately" {
  export FAKE_SCENARIO=throttle FAKE_ADS="AD-1 AD-2" TRY_FAULT_DOMAINS=true
  run_module
  assert_result 2 retry throttled
  assert_call_count "$CALL_APPLY" 1
  assert_call_count "$CALL_CAPACITY" 1
}

@test "L: state lock error on apply => fatal state_locked with force-unlock guidance" {
  export FAKE_SCENARIO=lock FAKE_ADS="AD-1 AD-2"
  run_module
  assert_result 1 fatal state_locked
  assert_call_count "$CALL_APPLY" 1
  assert_summary_contains "force-unlock -force $LOCK_ID"
  assert_summary_contains "ID \`$LOCK_ID\`"
}

@test "L: a denied lock PUT (404 BucketNotFound) is auth, not state_locked" {
  export FAKE_APPLY='*=lock-put-denied'
  run_module
  assert_result 1 fatal auth
  refute_summary_contains "force-unlock"
}

@test "M: unknown apply error => fatal error" {
  export FAKE_SCENARIO=unknown_error FAKE_ADS="AD-1 AD-2"
  run_module
  assert_result 1 fatal error
  assert_call_count "$CALL_APPLY" 1
  assert_summary_contains "400-InvalidParameter, Invalid subnetId"
}

@test "M: a variable validation failure is a fatal error" {
  export FAKE_APPLY='*=validation-error'
  run_module
  assert_result 1 fatal error
}

@test "N: every missing required setting is listed by name and nothing runs" {
  unset TENANCY_OCID OCI_STATE_BUCKET OCI_STATE_NAMESPACE TF_VAR_ssh_public_key
  run_module
  assert_result 1 fatal missing_config
  assert_output_value message "Missing required settings: TENANCY_OCID OCI_STATE_BUCKET OCI_STATE_NAMESPACE TF_VAR_ssh_public_key"
  assert_summary_contains '`TENANCY_OCID` (from secret OCI_TENANCY_OCID)'
  assert_summary_contains '`OCI_STATE_BUCKET` (from variable OCI_STATE_BUCKET)'
  assert_summary_contains '`OCI_STATE_NAMESPACE` (from secret OCI_STATE_NAMESPACE)'
  assert_summary_contains '`TF_VAR_ssh_public_key` (from secret ORACLE_A1_SSH_PUBLIC_KEY)'
  assert_contains "$stderr" "missing required setting: TF_VAR_ssh_public_key"
  [ ! -s "$FAKE_CALLS" ]
}

@test "N: provided secret values never appear when others are missing" {
  unset OCI_STATE_BUCKET
  export OCI_STATE_NAMESPACE=""
  run_module
  assert_result 1 fatal missing_config
  assert_output_value message "Missing required settings: OCI_STATE_BUCKET OCI_STATE_NAMESPACE"
  refute_contains "$(gh_output message)" TENANCY_OCID
  assert_no_secret_leak
  [ ! -s "$FAKE_CALLS" ]
}

@test "O: capacity report CLI error is inconclusive => apply attempted anyway" {
  export FAKE_SCENARIO=report_error
  run_module
  assert_result 0 "done" instance_created
  assert_call_order "$CALL_CAPACITY" "$CALL_APPLY_CREATE"
  assert_contains "$stderr" "inconclusive (CLI error"
}

@test "O: empty or UNKNOWN_ENUM_VALUE reports are inconclusive too" {
  export FAKE_SCENARIO=report_empty
  run_module
  assert_result 0 "done" instance_created
  assert_called "$CALL_APPLY_CREATE"
  new_run
  rm -f "$FAKE_STATE_DIR/state.json"
  export FAKE_SCENARIO=happy FAKE_CAPACITY=UNKNOWN_ENUM_VALUE
  run_module
  assert_result 0 "done" instance_created
  assert_contains "$stderr" "inconclusive ('UNKNOWN_ENUM_VALUE'"
}

@test "O: an unauthorised capacity report warns about the missing policy and still attempts" {
  export FAKE_CAPACITY=cli-capacity-notauthorized
  run_module
  assert_result 0 "done" instance_created
  assert_contains "$stderr" "manage compute-capacity-reports in tenancy"
}

@test "P: TRY_FAULT_DOMAINS=true, earlier placements hit capacity, FAULT-DOMAIN-2 succeeds" {
  export FAKE_SCENARIO=fault_domains TRY_FAULT_DOMAINS=true
  run_module
  assert_result 0 "done" instance_created
  assert_call_count "$CALL_APPLY" 3
  mapfile -t applies < <(grep -E "$CALL_APPLY_CREATE" "$FAKE_CALLS")
  [[ "${applies[0]}" == *" -var=fault_domain=" ]]
  [[ "${applies[1]}" == *" -var=fault_domain=FAULT-DOMAIN-1" ]]
  [[ "${applies[2]}" == *" -var=fault_domain=FAULT-DOMAIN-2" ]]
  refute_called "fault_domain=FAULT-DOMAIN-3"
  assert_output_value fault_domain FAULT-DOMAIN-2
  assert_call_count "$CALL_CAPACITY" 1
}

@test "Q: CAPACITY_CHECK=false => the capacity report is never called" {
  export CAPACITY_CHECK=false
  run_module
  assert_result 0 "done" instance_created
  refute_called "$CALL_CAPACITY"
  assert_called "$CALL_APPLY_CREATE"
}

# ------------------------------------------------------------------ reconcile and safety

@test "R1: tracked instance still TERMINATING => retry terminating, nothing applied" {
  export FAKE_SCENARIO=terminating
  run_module
  assert_result 2 retry terminating
  refute_called "$CALL_APPLY"
  refute_called "$CALL_STATE_RM"
  refute_called "$CALL_INSTANCES"
}

@test "R2: tainted but RUNNING => fatal refuse_destructive with untaint guidance" {
  export FAKE_SCENARIO=tainted_running
  run_module
  assert_result 1 fatal refuse_destructive
  refute_called "$CALL_APPLY"
  refute_called "$CALL_STATE_RM"
  assert_contains "$(gh_output message)" "tainted but still RUNNING"
  assert_contains "$(gh_output message)" "untaint"
  assert_summary_contains "terraform -chdir=modules/oracle-a1/terraform untaint oci_core_instance.a1"
}

@test "R3: in state with an in-place update => the saved plan is applied, done instance_updated" {
  export FAKE_SCENARIO=in_state_update
  run_module
  assert_result 0 "done" instance_updated
  assert_call_count "$CALL_APPLY" 1
  refute_called "$CALL_APPLY_CREATE"
  local planned applied
  planned="$(grep -E "$CALL_PLAN" "$FAKE_CALLS" | grep -oE -- '-out=[^ ]+' | cut -d= -f2)"
  applied="$(grep -E "$CALL_APPLY_SAVED" "$FAKE_CALLS" | awk '{print $NF}')"
  [ -n "$planned" ]
  [ "$planned" = "$applied" ]
}

@test "R3: an output-only change (plan exit 2, resources no-op) is applied from the saved plan and reported as present" {
  export FAKE_SCENARIO=in_state_output_only
  run_module
  assert_result 0 "done" instance_present
  assert_called "$CALL_APPLY_SAVED"
}

@test "R4: the only untracked A1 is TERMINATING => retry terminating" {
  export FAKE_SCENARIO=orphan_terminating
  run_module
  assert_result 2 retry terminating
  refute_called "$CALL_CAPACITY"
  refute_called "$CALL_APPLY"
}

@test "R5: capacity reports say no capacity in both ADs => apply never called" {
  export FAKE_ADS="AD-1 AD-2" FAKE_CAPACITY="AD-1=OUT_OF_HOST_CAPACITY AD-2=OUT_OF_HOST_CAPACITY,HARDWARE_NOT_SUPPORTED"
  run_module
  assert_result 2 retry no_capacity
  refute_called "$CALL_APPLY"
  assert_call_count "$CALL_CAPACITY" 2
  assert_contains "$(gh_output message)" "Capacity reports show no A1 capacity"
  assert_summary_contains "| AD-2 | any | skipped: capacity report HARDWARE_NOT_SUPPORTED OUT_OF_HOST_CAPACITY |"
}

@test "R5: any AVAILABLE fault-domain entry in a report means attempt" {
  export FAKE_CAPACITY="OUT_OF_HOST_CAPACITY,AVAILABLE,OUT_OF_HOST_CAPACITY"
  run_module
  assert_result 0 "done" instance_created
}

@test "R6: async capacity failure leaves a1 in state => retry, no second apply" {
  export FAKE_SCENARIO=async_capacity FAKE_ADS="AD-1 AD-2" TRY_FAULT_DOMAINS=true
  run_module
  assert_result 2 retry no_capacity
  assert_call_count "$CALL_APPLY" 1
  assert_contains "$(gh_output message)" "still recorded in state"
  [ "$(jq -r '.values.root_module.resources[] | select(.address == "oci_core_instance.a1") | .tainted' "$FAKE_STATE_DIR/state.json")" = true ]
}

@test "R6: after an async failure the next runs wait, then recreate, and never destroy" {
  export FAKE_SCENARIO=async_capacity
  run_module
  assert_result 2 retry no_capacity

  jq '(.prior_state.values.root_module.resources[] | select(.address == "oci_core_instance.a1") | .values.state) = "TERMINATING"' \
    "$FIXTURES/terraform/plan-tainted-terminated.json" >"$BATS_TEST_TMPDIR/plan-tainted-terminating.json"
  new_run
  export FAKE_SCENARIO=happy FAKE_PLAN_JSON="$BATS_TEST_TMPDIR/plan-tainted-terminating.json"
  run_module
  assert_result 2 retry terminating
  refute_called "$CALL_APPLY"

  new_run
  export FAKE_PLAN_JSON=plan-dropped.json FAKE_REFRESH_DROPS_A1=true
  run_module
  assert_result 0 "done" instance_created
  refute_called "$CALL_APPLY_SAVED"
}

@test "R7: MAX_RUN_SECONDS=0 => no apply, retry no_capacity" {
  export MAX_RUN_SECONDS=0
  run_module
  assert_result 2 retry no_capacity
  refute_called "$CALL_APPLY"
  assert_contains "$(gh_output message)" "MAX_RUN_SECONDS=0"
}

@test "R8: invalid OCPUS => fatal invalid_config before any CLI call" {
  local bad
  for bad in 5 0 two 2.5; do
    new_run
    export OCPUS="$bad"
    run_module
    assert_result 1 fatal invalid_config
    assert_contains "$(gh_output message)" "OCPUS must be a whole number 1-4 (got '$bad')"
    [ ! -s "$FAKE_CALLS" ]
  done
}

@test "R8: every invalid setting is reported together, and a bad TENANCY_OCID is not echoed" {
  export OCPUS=9 MEMORY_GB=25 CAPACITY_CHECK=yes TRY_FAULT_DOMAINS=1 SLEEP_BETWEEN=soon MAX_RUN_SECONDS=-1 OCI_REGION=Sydney
  export TENANCY_OCID="ocid1.user.oc1..aaaaaaaanottenancysecretvalue"
  run_module
  assert_result 1 fatal invalid_config
  local message
  message="$(gh_output message)"
  for want in "TENANCY_OCID must start with ocid1.tenancy." "OCPUS must" "MEMORY_GB must" "CAPACITY_CHECK must" \
    "TRY_FAULT_DOMAINS must" "SLEEP_BETWEEN must" "MAX_RUN_SECONDS must" "OCI_REGION must"; do
    assert_contains "$message" "$want"
  done
  assert_no_secret_leak "ocid1.user.oc1..aaaaaaaanottenancysecretvalue"
  [ ! -s "$FAKE_CALLS" ]
}

@test "R9: CLI throttle while listing ADs => retry throttled" {
  export FAKE_SCENARIO=ad_throttle
  run_module
  assert_result 2 retry throttled
  refute_called "$CALL_TF"
  assert_summary_contains "TransientServiceError"
}

@test "R10: every -var name run.sh passes is declared in variables.tf" {
  local name names=() missing=()
  mapfile -t names < <(grep -oE -- '-var="?[a-z_]+=' "$RUN_SH" | sed -E 's/^-var="?//; s/=$//' | sort -u)
  [ "${#names[@]}" -ge 2 ]
  for name in "${names[@]}"; do
    grep -qE "^variable \"$name\" \\{" "$TF_MODULE_DIR/variables.tf" || missing+=("$name")
  done
  [ "${#missing[@]}" -eq 0 ] || fail_with "undeclared -var names: ${missing[*]}"
}

@test "R10: every TF_VAR_* that run.sh exports or the workflow passes is declared" {
  local name names=() missing=() workflow="$REPO_ROOT/.github/workflows/oracle-a1.yml"
  mapfile -t names < <(grep -ohE 'TF_VAR_[a-z_]+' "$RUN_SH" | sed 's/^TF_VAR_//' | sort -u)
  if [[ -f "$workflow" ]]; then
    mapfile -t -O "${#names[@]}" names < <(grep -oE 'TF_VAR_[a-z_]+' "$workflow" | sed 's/^TF_VAR_//' | sort -u)
  fi
  for name in "${names[@]}"; do
    grep -qE "^variable \"$name\" \\{" "$TF_MODULE_DIR/variables.tf" || missing+=("$name")
  done
  [ "${#missing[@]}" -eq 0 ] || fail_with "undeclared TF_VAR names: ${missing[*]}"
}

@test "R10: every -var recorded during real runs is declared" {
  export FAKE_SCENARIO=fault_domains TRY_FAULT_DOMAINS=true
  run_module
  assert_result 0 "done" instance_created
  new_run
  rm -f "$FAKE_STATE_DIR/state.json"
  export FAKE_SCENARIO=in_state_update TRY_FAULT_DOMAINS=false
  run_module
  assert_result 0 "done" instance_updated
  local name
  while IFS= read -r name; do
    grep -qE "^variable \"$name\" \\{" "$TF_MODULE_DIR/variables.tf" || fail_with "undeclared variable $name"
  done < <(grep -hoE -- ' -var=[a-z_]+=' "$FAKE_CALLS" | sed -E 's/^ -var=//; s/=$//' | sort -u)
}

@test "R11: retries.json has only 3-digit status keys and bounded integer fields" {
  local file="$TF_MODULE_DIR/retries.json"
  jq -e 'type == "object" and length > 0' "$file" >/dev/null
  jq -e 'keys | all(test("^[0-9]{3}$"))' "$file" >/dev/null || fail_with "non-status keys in retries.json"
  jq -e '[.[] | type == "object" and length > 0 and (keys - ["retry_max_duration", "first_retry_sleep_duration"] | length == 0)] | all' \
    "$file" >/dev/null || fail_with "unknown fields in retries.json"
  jq -e '[.[][] | type == "number" and . == floor and . >= 0 and . <= 600] | all' "$file" >/dev/null ||
    fail_with "retries.json values must be integers between 0 and 600"
}

@test "R11: retry budgets stay under the caps including the final backoff overshoot" {
  local file="$TF_MODULE_DIR/retries.json"
  jq -e '(.["500"].retry_max_duration // 0) * 1.05 + 1 <= 60' "$file" >/dev/null || fail_with "500 budget exceeds 60 s"
  jq -e '[.["409"], .["429"] | select(. != null) | .retry_max_duration * 1.05 + 1 <= 180] | all' "$file" >/dev/null ||
    fail_with "409/429 budget exceeds 180 s"
  jq -e '[.[] | (.first_retry_sleep_duration // 0) <= (.retry_max_duration // 0)] | all' "$file" >/dev/null
}

@test "R12: the step summary is written for done, retry and fatal and never leaks secrets" {
  local scenario want
  export TF_VAR_compartment_ocid="ocid1.compartment.oc1..aaaaaaaasecretcompartmentvalue"
  for scenario in "happy:done" apply_capacity:retry report_no_capacity:retry terminating:retry limit:fatal \
    orphan:fatal lock:fatal auth_probe:fatal in_state_replace:fatal tainted_running:fatal unknown_error:fatal; do
    new_run
    rm -f "$FAKE_STATE_DIR/state.json"
    export FAKE_SCENARIO="${scenario%%:*}"
    want="${scenario##*:}"
    run_module
    [ "$(gh_output status)" = "$want" ] || fail_with "$FAKE_SCENARIO: want status $want"
    [ -s "$GITHUB_STEP_SUMMARY" ] || fail_with "$FAKE_SCENARIO: empty step summary"
    [[ "$(head -n1 "$GITHUB_STEP_SUMMARY")" == "## "*"oracle-a1: $want ("* ]] || fail_with "$FAKE_SCENARIO: bad heading"
    assert_no_secret_leak || fail_with "$FAKE_SCENARIO leaked a secret"
  done
}

@test "R12: fatal summaries say what to fix" {
  local scenario
  for scenario in limit orphan lock auth_probe in_state_replace unknown_error; do
    new_run
    rm -f "$FAKE_STATE_DIR/state.json"
    export FAKE_SCENARIO="$scenario"
    run_module
    assert_summary_contains "### What to fix" || fail_with "$scenario: no What to fix section"
  done
}

@test "R13: sleeps happen only between attempts (attempts - 1)" {
  export PATH="$SHIMS/pacing:$PATH" SLEEP_BETWEEN=7 TRY_FAULT_DOMAINS=true FAKE_APPLY='*=capacity'
  run_module
  assert_result 2 retry no_capacity
  assert_call_count "$CALL_APPLY" 4
  assert_call_count '^sleep ' 3
  assert_call_count '^sleep 7$' 3
  local sequence
  sequence="$(grep -E "^sleep |$CALL_APPLY" "$FAKE_CALLS" | sed -E 's/^sleep.*/S/; s/^terraform.*/A/' | tr -d '\n')"
  [ "$sequence" = ASASASA ] || fail_with "unexpected apply/sleep sequence $sequence"
}

@test "R13: a skipped AD costs no sleep and an immediate success sleeps not at all" {
  export PATH="$SHIMS/pacing:$PATH" SLEEP_BETWEEN=3 TRY_FAULT_DOMAINS=true FAKE_ADS="AD-1 AD-2"
  export FAKE_CAPACITY="AD-1=OUT_OF_HOST_CAPACITY AD-2=AVAILABLE" FAKE_APPLY='*=capacity'
  run_module
  assert_result 2 retry no_capacity
  assert_call_count "$CALL_APPLY" 4
  assert_call_count '^sleep ' 3
  new_run
  rm -f "$FAKE_STATE_DIR/state.json"
  unset FAKE_CAPACITY FAKE_APPLY
  run_module
  assert_result 0 "done" instance_created
  assert_call_count '^sleep ' 0
}

@test "R13: SLEEP_BETWEEN=0 never sleeps" {
  export PATH="$SHIMS/pacing:$PATH" TRY_FAULT_DOMAINS=true FAKE_APPLY='*=capacity'
  run_module
  assert_result 2 retry no_capacity
  assert_call_count '^sleep ' 0
}

@test "R14: lock error during the reconcile plan => fatal state_locked with force-unlock and the lock ID" {
  export FAKE_SCENARIO=reconcile_lock
  run_module
  assert_result 1 fatal state_locked
  refute_called "$CALL_APPLY"
  assert_contains "$(gh_output message)" "terraform plan (reconcile)"
  assert_summary_contains "terraform -chdir=modules/oracle-a1/terraform force-unlock -force $LOCK_ID"
  assert_summary_contains "-backend-config=\"bucket=$TEST_BUCKET\""
}

# ------------------------------------------------------------------ other failure paths

@test "init failing with a backend 401 => fatal auth before any state read" {
  export FAKE_TF_INIT=backend-auth
  run_module
  assert_result 1 fatal auth
  refute_called "$CALL_SHOW_STATE"
  assert_contains "$(gh_output message)" "terraform init"
}

@test "validate failing => fatal error" {
  export FAKE_TF_VALIDATE=validation-error
  run_module
  assert_result 1 fatal error
  refute_called "$CALL_SHOW_STATE"
}

@test "reading state failing with a lock-free backend auth error => fatal auth" {
  export FAKE_SHOW_STATE=backend-auth
  run_module
  assert_result 1 fatal auth
  refute_called "$CALL_APPLY"
}

@test "state rm failing on the lock during recovery => fatal state_locked" {
  export FAKE_SCENARIO=terminated_in_state FAKE_STATE_RM=lock
  run_module
  assert_result 1 fatal state_locked
  refute_called "$CALL_APPLY"
}

@test "the reconcile plan failing for another reason => fatal error" {
  export FAKE_SCENARIO=in_state_no_changes FAKE_PLAN_LOG=other
  run_module
  assert_result 1 fatal error
  refute_called "$CALL_APPLY"
}

@test "the saved-plan apply failing is classified" {
  export FAKE_SCENARIO=in_state_update FAKE_PLAN_APPLY=throttle-tenant
  run_module
  assert_result 2 retry throttled
}

@test "orphan guard: throttled listing => retry, unauthorised listing => fatal auth" {
  export FAKE_INSTANCE_LIST=cli-instances-throttle
  run_module
  assert_result 2 retry throttled
  new_run
  export FAKE_INSTANCE_LIST=cli-instances-notauthorized
  run_module
  assert_result 1 fatal auth
  refute_called "$CALL_APPLY"
}

@test "an empty AD list is fatal auth" {
  export FAKE_AD_LIST=empty
  run_module
  assert_result 1 fatal auth
  assert_contains "$(gh_output message)" "No availability domains returned for ap-sydney-1"
}

@test "missing OCI CLI config => fatal missing_config; OCI_CLI_CONFIG_FILE is honoured" {
  rm -f "$HOME/.oci/config"
  run_module
  assert_result 1 fatal missing_config
  assert_contains "$(gh_output message)" "$HOME/.oci/config"
  [ ! -s "$FAKE_CALLS" ]
  new_run
  : >"$BATS_TEST_TMPDIR/custom-config"
  export OCI_CLI_CONFIG_FILE="$BATS_TEST_TMPDIR/custom-config"
  run_module
  assert_result 0 "done" instance_created
}

@test "missing terraform binary => fatal missing_tool" {
  local bin="$BATS_TEST_TMPDIR/minimal-bin" tool
  mkdir -p "$bin"
  for tool in bash dirname date od tr sed grep cat tail head mktemp basename jq; do
    ln -s "$(command -v "$tool")" "$bin/$tool"
  done
  run --separate-stderr env PATH="$bin" "$RUN_SH"
  assert_result 1 fatal missing_tool
  assert_output_value message "Required command not found: terraform"
}

@test "sizing has one source of truth: OCPUS/MEMORY_GB drive the report, TF_VAR_* and outputs" {
  export OCPUS=1 MEMORY_GB=6
  run_module
  assert_result 0 "done" instance_created
  assert_called "$CALL_CAPACITY .*\"instanceShapeConfig\":\\{\"ocpus\":1,\"memoryInGBs\":6\\}"
  grep -qx 'TF_VAR_ocpus=1' "$FAKE_STATE_DIR/env.apply"
  grep -qx 'TF_VAR_memory_in_gbs=6' "$FAKE_STATE_DIR/env.apply"
  grep -qx "TF_VAR_tenancy_ocid=$TEST_TENANCY" "$FAKE_STATE_DIR/env.apply"
  grep -qx 'TF_VAR_region=ap-sydney-1' "$FAKE_STATE_DIR/env.apply"
  grep -qx 'TF_IN_AUTOMATION=1' "$FAKE_STATE_DIR/env.apply"
  assert_output_value ocpus 1
  assert_output_value memory_in_gbs 6
  refute_contains "$stderr" "exceeds the Always Free A1 allowance"
}

@test "sizing above the free allowance warns but proceeds" {
  export OCPUS=4 MEMORY_GB=24
  run_module
  assert_result 0 "done" instance_created
  assert_contains "$stderr" "exceeds the Always Free A1 allowance"
}

@test "the capacity report always uses the tenancy; the orphan guard uses the target compartment" {
  export TF_VAR_compartment_ocid="ocid1.compartment.oc1..aaaaaaaatargetcompartment"
  run_module
  assert_result 0 "done" instance_created
  assert_called "$CALL_CAPACITY .*--compartment-id $TEST_TENANCY "
  assert_called "$CALL_INSTANCES .*--compartment-id ocid1\\.compartment\\.oc1\\.\\.aaaaaaaatargetcompartment "
}

@test "a created instance without a public IP is still done, with a warning" {
  export FAKE_PUBLIC_IP=""
  run_module
  assert_result 0 "done" instance_created
  assert_output_value public_ip ""
  assert_output_value ssh_command ""
  assert_contains "$(gh_output message)" "no public IP"
  assert_contains "$stderr" "no public IP in state"
}

@test "real AD names with a tenancy prefix are passed through intact" {
  export FAKE_ADS="kIdk:AP-SYDNEY-1-AD-1"
  run_module
  assert_result 0 "done" instance_created
  assert_called "$CALL_APPLY_CREATE .*-var=instance_availability_domain=kIdk:AP-SYDNEY-1-AD-1 "
  assert_output_value availability_domain "kIdk:AP-SYDNEY-1-AD-1"
}

@test "state holding only the network (after earlier misses) takes the create path, not reconcile" {
  export FAKE_STATE=state-network-only.json
  run_module
  assert_result 0 "done" instance_created
  refute_called "$CALL_PLAN"
}

@test "local runs without GITHUB_OUTPUT or GITHUB_STEP_SUMMARY print the summary to stdout" {
  unset GITHUB_OUTPUT GITHUB_STEP_SUMMARY
  run_module
  [ "$status" -eq 0 ]
  assert_contains "$output" "## ✅ oracle-a1: done (instance_created)"
  refute_contains "$stderr" "No such file"
}

@test "inside Actions the outcome is annotated and no secret is written to the log" {
  export GITHUB_ACTIONS=true FAKE_SCENARIO=limit
  run_module
  assert_result 1 fatal limit_exceeded
  assert_contains "$output" "::error::OCI service limit exceeded"
  assert_no_secret_leak
}

# ------------------------------------------------------------------ shim contract

@test "shim: oci instance list prints nothing at all when the compartment is empty" {
  run --separate-stderr oci compute instance list --compartment-id x --all
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
  assert_called '^oci compute instance list --compartment-id x --all$'
}

@test "shim: oci list output uses the CLI's pretty kebab-case JSON" {
  export FAKE_INSTANCE_LIST=instances-orphan.json
  run --separate-stderr oci compute instance list --compartment-id x --all
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "{" ]
  [ "${lines[1]}" = '  "data": [' ]
  [ "$(jq -r '.data[1]."lifecycle-state"' <<<"$output")" = RUNNING ]
  export FAKE_ADS="AD-1 AD-2"
  run --separate-stderr oci iam availability-domain list --compartment-id x --query 'data[].name'
  [ "$output" = $'[\n  "AD-1",\n  "AD-2"\n]' ]
}

@test "shim: oci capacity report answers per AD and validates its options like the CLI" {
  export FAKE_CAPACITY="AD-2=OUT_OF_HOST_CAPACITY,AVAILABLE HARDWARE_NOT_SUPPORTED"
  run --separate-stderr oci compute compute-capacity-report create --availability-domain AD-2 --compartment-id t \
    --shape-availabilities '[{"instanceShape":"VM.Standard.A1.Flex"}]' --query 'data."shape-availabilities"[]."availability-status"'
  [ "$output" = $'[\n  "OUT_OF_HOST_CAPACITY",\n  "AVAILABLE"\n]' ]
  run --separate-stderr oci compute compute-capacity-report create --availability-domain AD-1 --compartment-id t \
    --shape-availabilities '[{"instanceShape":"VM.Standard.A1.Flex"}]' --query 'data."shape-availabilities"[0]."availability-status"' --raw-output
  [ "$output" = HARDWARE_NOT_SUPPORTED ]
  run --separate-stderr oci compute compute-capacity-report create --availability-domain AD-1 --shape-availabilities '[]'
  [ "$status" -eq 1 ]
  [ "$stderr" = "Error: Missing option(s) --compartment-id." ]
  run --separate-stderr oci compute compute-capacity-report create --availability-domain AD-1 --compartment-id t --shape-availabilities 'nope'
  [ "$status" -eq 1 ]
  export FAKE_CAPACITY=error
  run --separate-stderr oci compute compute-capacity-report create --availability-domain AD-1 --compartment-id t --shape-availabilities '[]'
  [ "$status" -eq 1 ]
  [ "${stderr_lines[0]}" = "TransientServiceError:" ]
}

@test "shim: oci CLI errors go to stderr with the real headers" {
  export FAKE_AD_LIST=auth
  run --separate-stderr oci iam availability-domain list --compartment-id x --query 'data[].name'
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ "${stderr_lines[0]}" = "ServiceError:" ]
  export FAKE_AD_LIST=throttle
  run --separate-stderr oci iam availability-domain list --compartment-id x --query 'data[].name'
  [ "${stderr_lines[0]}" = "TransientServiceError:" ]
  run --separate-stderr oci compute nonsense list
  [ "$status" -eq 2 ]
}

@test "shim: terraform show -json of an empty backend is the bare format_version document" {
  run --separate-stderr terraform -chdir="$TF_MODULE_DIR" show -json -no-color
  [ "$status" -eq 0 ]
  [ "$output" = '{"format_version":"1.0"}' ]
}

@test "shim: terraform rejects undeclared -var names and missing required variables like Terraform" {
  export TF_VAR_tenancy_ocid="$TEST_TENANCY"
  run --separate-stderr terraform -chdir="$TF_MODULE_DIR" apply -input=false -no-color -auto-approve -var=placement=AD-1
  [ "$status" -eq 1 ]
  assert_contains "$stderr" 'Error: Value for undeclared variable'
  assert_contains "$stderr" 'A variable named "placement" was assigned on the command line'
  unset TF_VAR_tenancy_ocid
  run --separate-stderr terraform -chdir="$TF_MODULE_DIR" plan -input=false -no-color -var=instance_availability_domain=AD-1
  [ "$status" -eq 1 ]
  assert_contains "$stderr" 'Error: No value for required variable'
  assert_contains "$stderr" '   1: variable "tenancy_ocid" {'
  export TF_VAR_tenancy_ocid="$TEST_TENANCY"
  run --separate-stderr terraform -chdir="$TF_MODULE_DIR" apply -input=false -no-color -auto-approve -var=fault_domain=FAULT-DOMAIN-4
  [ "$status" -eq 1 ]
  assert_contains "$stderr" 'Error: Invalid value for variable'
  run --separate-stderr terraform -chdir="$TF_MODULE_DIR" plan -refresh=false
  [ "$status" -eq 1 ]
}

@test "shim: terraform apply records the AD and FD actually used, state rm removes it" {
  export TF_VAR_tenancy_ocid="$TEST_TENANCY"
  run --separate-stderr terraform -chdir="$TF_MODULE_DIR" apply -input=false -no-color -auto-approve \
    -var=instance_availability_domain=AD-9 -var=fault_domain=FAULT-DOMAIN-3
  [ "$status" -eq 0 ]
  assert_contains "$output" "Apply complete! Resources: 1 added, 0 changed, 0 destroyed."
  run --separate-stderr terraform -chdir="$TF_MODULE_DIR" output -json -no-color
  [ "$(jq -r '.availability_domain.value + "/" + .fault_domain.value' <<<"$output")" = AD-9/FAULT-DOMAIN-3 ]
  run --separate-stderr terraform -chdir="$TF_MODULE_DIR" state rm -lock-timeout=60s oci_core_instance.a1
  [ "$status" -eq 0 ]
  run --separate-stderr terraform -chdir="$TF_MODULE_DIR" show -json -no-color
  [ "$(jq '[.values.root_module.resources[] | select(.address == "oci_core_instance.a1")] | length' <<<"$output")" = 0 ]
  run --separate-stderr terraform -chdir="$TF_MODULE_DIR" state rm oci_core_instance.a1
  [ "$status" -eq 1 ]
  refute_tripwire
}

@test "shim: terraform plan exit code follows the plan fixture and the plan file is required by show" {
  export TF_VAR_tenancy_ocid="$TEST_TENANCY" FAKE_STATE=state-running.json FAKE_PLAN_JSON=plan-no-changes.json
  run --separate-stderr terraform -chdir="$TF_MODULE_DIR" plan -detailed-exitcode -out="$BATS_TEST_TMPDIR/p.tfplan"
  [ "$status" -eq 0 ]
  assert_contains "$output" "No changes. Your infrastructure matches the configuration."
  export FAKE_PLAN_JSON=plan-replace.json
  run --separate-stderr terraform -chdir="$TF_MODULE_DIR" plan -detailed-exitcode -out="$BATS_TEST_TMPDIR/p.tfplan"
  [ "$status" -eq 2 ]
  assert_contains "$output" "# oci_core_instance.a1 must be replaced"
  run --separate-stderr terraform -chdir="$TF_MODULE_DIR" plan -out="$BATS_TEST_TMPDIR/p.tfplan"
  [ "$status" -eq 0 ]
  run --separate-stderr terraform -chdir="$TF_MODULE_DIR" show -json -no-color "$BATS_TEST_TMPDIR/p.tfplan"
  [ "$(jq -r .format_version <<<"$output")" = 1.2 ]
  run --separate-stderr terraform -chdir="$TF_MODULE_DIR" show -json -no-color "$BATS_TEST_TMPDIR/absent.tfplan"
  [ "$status" -eq 1 ]
}

@test "shim: every invocation is recorded and an unknown scenario fails loudly" {
  run oci compute instance list --compartment-id c --all
  run terraform -chdir="$TF_MODULE_DIR" version
  [ "$(wc -l <"$FAKE_CALLS")" -eq 2 ]
  export FAKE_SCENARIO=typo
  run --separate-stderr oci compute instance list --compartment-id c
  [ "$status" -eq 98 ]
  assert_contains "$stderr" "unknown FAKE_SCENARIO typo"
}

@test "R15: a private key pasted as the SSH public key is rejected before any OCI call and never echoed" {
  local body="b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQpastedPrivateBody"
  export TF_VAR_ssh_public_key="-----BEGIN OPENSSH ""PRIVATE KEY-----"$'\n'"${body}"$'\n'"-----END OPENSSH ""PRIVATE KEY-----"
  run_module
  assert_result 1 fatal invalid_config
  assert_contains "$(gh_output message)" "ORACLE_A1_SSH_PUBLIC_KEY must be SSH public key text"
  assert_no_secret_leak "$body"
  [ ! -s "$FAKE_CALLS" ]
}

@test "R16: whitespace and CR around secrets are trimmed before they reach OCI or Terraform" {
  export FAKE_SCENARIO=happy
  export TENANCY_OCID="  ${TEST_TENANCY}"$'\r\n'
  export OCI_STATE_NAMESPACE="${TEST_NAMESPACE}"$'\n'
  export TF_VAR_ssh_public_key="${TEST_SSH_KEY}"$'\n'
  run_module
  assert_result 0 done instance_created
  assert_called "^oci iam availability-domain list .*--compartment-id ${TEST_TENANCY} "
  assert_called "-backend-config=namespace=${TEST_NAMESPACE} "
  if grep -q $'\r' "$FAKE_CALLS"; then
    fail_with "a carriage return reached a command line"
  fi
}

@test "R17: a terraform.tfvars or *.auto.tfvars in TF_DIR is refused because it would override run.sh" {
  local dir="$BATS_TEST_TMPDIR/tfdir" name
  for name in terraform.tfvars terraform.tfvars.json local.auto.tfvars local.auto.tfvars.json; do
    rm -rf "$dir"
    mkdir -p "$dir"
    cp "$TF_MODULE_DIR"/*.tf "$dir"/
    printf 'ocpus = 2\n' >"$dir/$name"
    export TF_DIR="$dir"
    new_run
    run_module
    assert_result 1 fatal invalid_config
    assert_contains "$(gh_output message)" "$name in TF_DIR would override"
    [ ! -s "$FAKE_CALLS" ]
  done
}

@test "R18: orphan import guidance carries region and sizing and has slots for compartment and subnet" {
  export FAKE_SCENARIO=orphan OCI_REGION=ap-melbourne-1 OCPUS=1 MEMORY_GB=6
  run_module
  assert_result 1 fatal orphan
  assert_summary_contains "TF_VAR_region=ap-melbourne-1 TF_VAR_ocpus=1 TF_VAR_memory_in_gbs=6"
  assert_summary_contains "TF_VAR_compartment_ocid='<OCI_COMPARTMENT_OCID or empty>'"
  assert_summary_contains "TF_VAR_existing_subnet_id='<OCI_SUBNET_OCID or empty>'"
  assert_no_secret_leak
}

@test "R19: a launch accepted then failed without capacity wording leaves a1 in state => retry launch_failed, one apply" {
  export FAKE_SCENARIO=happy FAKE_APPLY='*=async:workrequest-empty' FAKE_ADS="AD-1 AD-2" TRY_FAULT_DOMAINS=true
  run_module
  assert_result 2 retry launch_failed
  assert_call_count "$CALL_APPLY" 1
  refute_summary_contains "does not fix itself"
}

@test "R19: an ordinary non-capacity failure with nothing left in state is still fatal error" {
  export FAKE_SCENARIO=unknown_error
  run_module
  assert_result 1 fatal error
}

@test "R20: SLEEP_BETWEEN and MAX_RUN_SECONDS reject leading zeros (bash would read them as octal)" {
  export SLEEP_BETWEEN=08 MAX_RUN_SECONDS=0900
  run_module
  assert_result 1 fatal invalid_config
  assert_contains "$(gh_output message)" "SLEEP_BETWEEN must be a whole number of seconds without leading zeros"
  assert_contains "$(gh_output message)" "MAX_RUN_SECONDS must be a whole number of seconds without leading zeros"
  [ ! -s "$FAKE_CALLS" ]
}

@test "R21: an unclassified orphan-guard failure (500) is fatal error and never reaches apply; --all is passed" {
  export FAKE_SCENARIO=happy FAKE_INSTANCE_LIST=cli-capacity-error
  run_module
  assert_result 1 fatal error
  assert_called "$CALL_INSTANCES .*--all"
  refute_called "$CALL_CAPACITY"
  refute_called "$CALL_APPLY"
}

@test "R22: OCI_REGION reaches TF_VAR_region, the backend and every OCI CLI call" {
  export FAKE_SCENARIO=happy OCI_REGION=ap-melbourne-1
  run_module
  assert_result 0 "done" instance_created
  grep -qx 'TF_VAR_region=ap-melbourne-1' "$FAKE_STATE_DIR/env.apply"
  assert_called "$CALL_INIT.*-backend-config=region=ap-melbourne-1"
  assert_called "$CALL_AD_LIST .*--region ap-melbourne-1"
  assert_called "$CALL_INSTANCES .*--region ap-melbourne-1"
  assert_called "$CALL_CAPACITY .*--region ap-melbourne-1"
}

@test "R23: defaults pace at 20s between attempts and bound the run at 600s" {
  unset SLEEP_BETWEEN
  export PATH="$SHIMS/pacing:$PATH" TRY_FAULT_DOMAINS=true FAKE_APPLY='*=capacity'
  run_module
  assert_result 2 retry no_capacity
  assert_call_count '^sleep 20$' 3
  grep -qE '^MAX_RUN_SECONDS="\$\{MAX_RUN_SECONDS:-600\}"$' "$RUN_SH"
}

@test "R24: the reconcile plan and the saved-plan apply both wait for the lock" {
  export FAKE_SCENARIO=in_state_update
  run_module
  assert_result 0 "done" instance_updated
  assert_called "$CALL_PLAN.*-lock-timeout=60s .*-detailed-exitcode"
  assert_called '^terraform [^ ]+ apply .*-lock-timeout=60s .*reconcile\.tfplan$'
}
