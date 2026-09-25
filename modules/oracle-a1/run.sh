#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HUB_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../lib/common.sh
source "$HUB_ROOT/lib/common.sh"
# shellcheck source=lib/classify.sh
source "$SCRIPT_DIR/lib/classify.sh"

readonly SHAPE="VM.Standard.A1.Flex"
readonly INSTANCE_ADDR="oci_core_instance.a1"

OCI_REGION="${OCI_REGION:-ap-sydney-1}"
OCPUS="${OCPUS:-2}"
MEMORY_GB="${MEMORY_GB:-12}"
CAPACITY_CHECK="${CAPACITY_CHECK:-true}"
TRY_FAULT_DOMAINS="${TRY_FAULT_DOMAINS:-false}"
SLEEP_BETWEEN="${SLEEP_BETWEEN:-20}"
MAX_RUN_SECONDS="${MAX_RUN_SECONDS:-600}"
LOCK_TIMEOUT="${LOCK_TIMEOUT:-60s}"
TF_DIR="${TF_DIR:-$SCRIPT_DIR/terraform}"

ADS=()
ATTEMPT_ROWS=()
ATTEMPT_NO=0
WORK_DIR=""

hint_for() {
  case "$1" in
    TENANCY_OCID) printf 'secret OCI_TENANCY_OCID' ;;
    OCI_STATE_BUCKET) printf 'variable OCI_STATE_BUCKET' ;;
    OCI_STATE_NAMESPACE) printf 'secret OCI_STATE_NAMESPACE' ;;
    TF_VAR_ssh_public_key) printf 'secret ORACLE_A1_SSH_PUBLIC_KEY' ;;
    *) printf 'setting %s' "$1" ;;
  esac
}

# ---------------------------------------------------------------- reporting

summary_heading() {
  local status="$1" reason="$2" message="$3" icon
  case "$status" in
    done) icon="✅" ;;
    retry) icon="⏳" ;;
    skipped) icon="⏭️" ;;
    *) icon="❌" ;;
  esac
  summary_line "## ${icon} oracle-a1: ${status} (${reason})"
  summary_line ""
  summary_line "$message"
  summary_line ""
}

summary_attempts() {
  local row ad fd result
  ((${#ATTEMPT_ROWS[@]} > 0)) || return 0
  local cells=()
  for row in "${ATTEMPT_ROWS[@]}"; do
    IFS=$'\x1f' read -r ad fd result <<<"$row"
    cells+=("$ad" "${fd:-any}" "$result")
  done
  summary_line "### Attempts"
  summary_line ""
  summary_table 3 "Availability domain" "Fault domain" "Result" "${cells[@]}"
  summary_line ""
}

record_attempt() {
  ATTEMPT_ROWS+=("$1"$'\x1f'"$2"$'\x1f'"$3")
}

# Usage: conclude STATUS REASON MESSAGE [GUIDANCE_MARKDOWN] [LOGFILE]
conclude() {
  local status="$1" reason="$2" message="$3" guidance="${4:-}" logfile="${5:-}"
  summary_heading "$status" "$reason" "$message"
  if [[ -n "$guidance" ]]; then
    if [[ "$status" == "fatal" ]]; then
      summary_line "### What to fix"
    else
      summary_line "### What happens next"
    fi
    summary_line ""
    summary_line "$guidance"
    summary_line ""
  fi
  summary_attempts
  if [[ -n "$logfile" ]]; then
    summary_details "Log tail ($(basename "$logfile"))" "$logfile" 60
  fi
  finish "$status" "$reason" "$message"
}

backend_init_hint() {
  printf 'terraform -chdir=modules/oracle-a1/terraform init -backend-config="bucket=%s" -backend-config="namespace=<OCI_STATE_NAMESPACE>" -backend-config="region=%s"' \
    "${OCI_STATE_BUCKET:-<OCI_STATE_BUCKET>}" "$OCI_REGION"
}

auth_guidance() {
  cat <<'EOF'
OCI rejected the request as unauthenticated or unauthorised. Check, in this order:

1. `OCI_PRIVATE_KEY` is the **API signing key** PEM (a `BEGIN PRIVATE KEY` block), not an SSH key.
2. `OCI_FINGERPRINT` belongs to that key and `OCI_USER_OCID` / `OCI_TENANCY_OCID` are correct.
3. `OCI_REGION` is the tenancy's **home region** (`scripts/check-home-region.sh`).
4. The policy in `bootstrap/oracle/iam-policy.txt` exists in the **root** compartment for the automation group.
5. `OCI_STATE_BUCKET` / `OCI_STATE_NAMESPACE` name the bucket created by `bootstrap/oracle/create-state-bucket.sh`.
EOF
}

fail_class() {
  local class="$1" context="$2" logfile="${3:-}" lock_id lock_note="" guidance
  case "$class" in
    limit)
      guidance="The tenancy's A1 allowance (2 OCPU / 12 GB on Always Free) is already in use, or OCPUS/MEMORY_GB exceed it. Retrying cannot succeed.

- Look for another \`${SHAPE}\` instance in **any** compartment (the orphan guard only checks the target compartment: \`OCI_COMPARTMENT_OCID\`, or the root compartment when it is unset), including one still \`TERMINATING\`.
- Keep \`ORACLE_A1_OCPUS\` / \`ORACLE_A1_MEMORY_GB\` at 2 / 12 or below."
      conclude fatal limit_exceeded "OCI service limit exceeded during ${context}." "$guidance" "$logfile"
      ;;
    lock)
      lock_id="$(lock_id_from_log "$logfile")"
      [[ -n "$lock_id" ]] && lock_note=" (ID \`${lock_id}\`)"
      guidance="Another Terraform operation holds the state lock${lock_note}. A run killed mid-operation leaves the lock behind.

1. Make sure no oracle-a1 workflow run or local Terraform command is in progress.
2. Release it locally with the same backend settings:

\`\`\`sh
$(backend_init_hint)
terraform -chdir=modules/oracle-a1/terraform force-unlock -force ${lock_id:-<LOCK_ID>}
\`\`\`"
      conclude fatal state_locked "Terraform state is locked (${context})." "$guidance" "$logfile"
      ;;
    auth)
      conclude fatal auth "Authentication or authorisation failed during ${context}." "$(auth_guidance)" "$logfile"
      ;;
    capacity)
      conclude retry no_capacity "Out of host capacity during ${context}." "The next scheduled run tries again." "$logfile"
      ;;
    throttle)
      conclude retry throttled "OCI is rate limiting requests (${context}); backing off until the next scheduled run." "The next scheduled run tries again. Nothing to fix unless this repeats for hours." "$logfile"
      ;;
    *)
      conclude fatal error "${context} failed for a reason that is not a capacity miss." "Read the log tail below. This does not fix itself: the schedule keeps failing until the cause is addressed." "$logfile"
      ;;
  esac
}

fail_from_log() {
  fail_class "$(classify_log "$1")" "$2" "$1"
}

# ---------------------------------------------------------------- helpers

tf_logged() {
  local logfile="$1"
  shift
  terraform -chdir="$TF_DIR" "$@" 2>&1 | tee "$logfile"
  return "${PIPESTATUS[0]}"
}

deadline_passed() {
  ((SECONDS >= MAX_RUN_SECONDS))
}

instance_in_state() {
  local out="$WORK_DIR/state.json" err="$WORK_DIR/state.err"
  if ! terraform -chdir="$TF_DIR" show -json -no-color >"$out" 2>"$err"; then
    fail_from_log "$err" "reading Terraform state"
  fi
  jq -e --arg a "$INSTANCE_ADDR" '[.values.root_module.resources[]? | select(.address == $a)] | length > 0' "$out" >/dev/null
}

# ---------------------------------------------------------------- steps

preflight() {
  local missing names name lines=() cmd cfg var
  for var in TENANCY_OCID OCI_REGION OCI_STATE_BUCKET OCI_STATE_NAMESPACE \
    TF_VAR_ssh_public_key TF_VAR_compartment_ocid TF_VAR_existing_subnet_id; do
    if [[ -n "${!var:-}" ]]; then
      printf -v "$var" '%s' "$(trim "${!var}")"
    fi
  done
  if ! missing="$(require_env TENANCY_OCID OCI_STATE_BUCKET OCI_STATE_NAMESPACE TF_VAR_ssh_public_key)"; then
    while IFS= read -r name; do
      lines+=("- \`${name}\` (from $(hint_for "$name"))")
      log "missing required setting: ${name} ($(hint_for "$name"))"
    done <<<"$missing"
    names="$(tr '\n' ' ' <<<"$missing")"
    conclude fatal missing_config "Missing required settings: ${names% }" \
      "Add these under **Settings → Secrets and variables → Actions** (values are never printed):

$(printf '%s\n' "${lines[@]}")"
  fi

  for cmd in terraform oci jq; do
    command -v "$cmd" >/dev/null 2>&1 ||
      conclude fatal missing_tool "Required command not found: ${cmd}" "Install \`${cmd}\` (the workflow does this via setup-terraform and setup-oci)."
  done

  cfg="${OCI_CLI_CONFIG_FILE:-$HOME/.oci/config}"
  [[ -r "$cfg" ]] ||
    conclude fatal missing_config "OCI CLI config not found at ${cfg}" "Run the \`setup-oci\` action first (locally: \`oci setup config\`)."

  local problems=()
  [[ "$TENANCY_OCID" =~ ^ocid1\.tenancy\. ]] || problems+=("TENANCY_OCID must start with ocid1.tenancy.")
  if [[ ! "$OCPUS" =~ ^[1-9][0-9]*$ ]] || ((OCPUS > 4)); then
    problems+=("OCPUS must be a whole number 1-4 (got '${OCPUS}')")
  fi
  if [[ ! "$MEMORY_GB" =~ ^[1-9][0-9]*$ ]] || ((MEMORY_GB > 24)); then
    problems+=("MEMORY_GB must be a whole number 1-24 (got '${MEMORY_GB}')")
  fi
  [[ "$CAPACITY_CHECK" == "true" || "$CAPACITY_CHECK" == "false" ]] || problems+=("CAPACITY_CHECK must be true or false (got '${CAPACITY_CHECK}')")
  [[ "$TRY_FAULT_DOMAINS" == "true" || "$TRY_FAULT_DOMAINS" == "false" ]] || problems+=("TRY_FAULT_DOMAINS must be true or false (got '${TRY_FAULT_DOMAINS}')")
  [[ "$SLEEP_BETWEEN" =~ ^(0|[1-9][0-9]*)$ ]] || problems+=("SLEEP_BETWEEN must be a whole number of seconds without leading zeros (got '${SLEEP_BETWEEN}')")
  [[ "$MAX_RUN_SECONDS" =~ ^(0|[1-9][0-9]*)$ ]] || problems+=("MAX_RUN_SECONDS must be a whole number of seconds without leading zeros (got '${MAX_RUN_SECONDS}')")
  [[ "$OCI_REGION" =~ ^[a-z]+(-[a-z]+)+-[0-9]+$ ]] || problems+=("OCI_REGION must look like ap-sydney-1 (got '${OCI_REGION}')")
  [[ "${TF_VAR_ssh_public_key:-}" =~ ^(ssh-ed25519 |ssh-rsa |ecdsa-sha2-) ]] ||
    problems+=("ORACLE_A1_SSH_PUBLIC_KEY must be SSH public key text starting with 'ssh-ed25519 ', 'ssh-rsa ' or 'ecdsa-sha2-' (not a private key or a file path)")
  compgen -G "$TF_DIR/*.tf" >/dev/null || problems+=("TF_DIR has no Terraform files: ${TF_DIR}")
  local tfvars
  for tfvars in "$TF_DIR"/terraform.tfvars "$TF_DIR"/terraform.tfvars.json "$TF_DIR"/*.auto.tfvars "$TF_DIR"/*.auto.tfvars.json; do
    if [[ -e "$tfvars" ]]; then
      problems+=("$(basename "$tfvars") in TF_DIR would override the settings run.sh passes to Terraform; move it away (run.sh takes all values from the environment)")
    fi
  done
  if ((${#problems[@]} > 0)); then
    conclude fatal invalid_config "Invalid configuration: ${problems[*]}" "$(printf -- '- %s\n' "${problems[@]}")"
  fi

  if ((OCPUS > 2 || MEMORY_GB > 12)); then
    warn "OCPUS=${OCPUS} / MEMORY_GB=${MEMORY_GB} exceeds the Always Free A1 allowance of 2 OCPU / 12 GB."
  fi

  COMPARTMENT="${TF_VAR_compartment_ocid:-$TENANCY_OCID}"
  export TF_VAR_tenancy_ocid="$TENANCY_OCID"
  export TF_VAR_region="$OCI_REGION"
  export TF_VAR_ocpus="$OCPUS"
  export TF_VAR_memory_in_gbs="$MEMORY_GB"
  export TF_IN_AUTOMATION=1 TF_INPUT=0 CHECKPOINT_DISABLE=1
  export SUPPRESS_LABEL_WARNING=True

  WORK_DIR="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/oracle-a1.XXXXXX")" ||
    conclude fatal error "Could not create a working directory." ""
  log "Working directory for logs: ${WORK_DIR}"
}

discover_ads() {
  local out err="$WORK_DIR/ads.err" rc
  log "Listing availability domains in ${OCI_REGION} (auth probe)..."
  out="$(oci iam availability-domain list --region "$OCI_REGION" --compartment-id "$TENANCY_OCID" \
    --query 'data[].name' --max-retries 3 </dev/null 2>"$err")"
  rc=$?
  if ((rc != 0)); then
    cat "$err" >&2
    if [[ "$(classify_log "$err")" == "throttle" ]]; then
      fail_class throttle "listing availability domains" "$err"
    fi
    conclude fatal auth "Could not list availability domains (auth probe failed)." "$(auth_guidance)" "$err"
  fi
  mapfile -t ADS < <(jq -r '.[]? // empty' <<<"${out:-[]}" 2>/dev/null)
  if ((${#ADS[@]} == 0)); then
    conclude fatal auth "No availability domains returned for ${OCI_REGION}." "$(auth_guidance)" "$err"
  fi
  log "Availability domains: ${ADS[*]}"
}

terraform_init() {
  local log_init="$WORK_DIR/init.log" log_validate="$WORK_DIR/validate.log"
  log "terraform init (remote state in bucket ${OCI_STATE_BUCKET})"
  tf_logged "$log_init" init -input=false -no-color -lockfile=readonly \
    -backend-config="bucket=${OCI_STATE_BUCKET}" \
    -backend-config="namespace=${OCI_STATE_NAMESPACE}" \
    -backend-config="region=${OCI_REGION}" ||
    fail_from_log "$log_init" "terraform init"
  tf_logged "$log_validate" validate -no-color ||
    fail_from_log "$log_validate" "terraform validate"
}

report_done() {
  local reason="$1" out="$WORK_DIR/outputs.json" err="$WORK_DIR/outputs.err" key value ip ad msg
  local keys=(public_ip instance_id availability_domain fault_domain image_name ocpus memory_in_gbs ssh_command)
  if ! terraform -chdir="$TF_DIR" output -json -no-color >"$out" 2>"$err"; then
    warn "terraform output failed; the instance exists but its details could not be read."
    printf '{}' >"$out"
  fi
  local cells=()
  for key in "${keys[@]}"; do
    value="$(jq -r --arg k "$key" '.[$k].value // "" | tostring' "$out" 2>/dev/null)"
    emit "$key" "$value"
    cells+=("$key" "${value:--}")
  done
  ip="$(jq -r '.public_ip.value // ""' "$out" 2>/dev/null)"
  ad="$(jq -r '.availability_domain.value // ""' "$out" 2>/dev/null)"
  if [[ -z "$ip" ]]; then
    warn "The instance has no public IP in state. Check the virtual-network-family policy and the subnet."
    msg="A1 instance is present (${ad:-AD unknown}) but no public IP was reported."
  else
    msg="A1 instance is ready at ${ip} (${ad}). SSH: $(jq -r '.ssh_command.value // ""' "$out")"
  fi
  summary_heading "done" "$reason" "$msg"
  summary_table 2 "Property" "Value" "${cells[@]}"
  summary_line ""
  summary_line "Next: SSH in, keep the VM doing something useful (Oracle reclaims idle Always Free instances), and remember the schedule is now disabled."
  summary_line ""
  summary_attempts
  finish "done" "$reason" "$msg"
}

refuse_destructive() {
  local detail="$1" guidance="$2" logfile="${3:-}"
  conclude fatal refuse_destructive "Refusing to destroy or replace the tracked A1 instance. ${detail}" "$guidance" "$logfile"
}

# Concludes the run itself, or returns when the create path should take over.
reconcile() {
  local plan_log="$WORK_DIR/reconcile-plan.log" apply_log="$WORK_DIR/reconcile-apply.log"
  local plan_file="$WORK_DIR/reconcile.tfplan" plan_json="$WORK_DIR/reconcile-plan.json"
  local rc prior state tainted actions changes resource_changes
  log "Instance is tracked in state: reconciling (a scheduled run never destroys or replaces it)."
  tf_logged "$plan_log" plan -input=false -no-color -lock-timeout="$LOCK_TIMEOUT" -detailed-exitcode \
    -out="$plan_file" -var="instance_availability_domain=${ADS[0]}"
  rc=$?
  if ((rc != 0 && rc != 2)); then
    fail_from_log "$plan_log" "terraform plan (reconcile)"
  fi
  if ! terraform -chdir="$TF_DIR" show -json -no-color "$plan_file" >"$plan_json" 2>"$WORK_DIR/show.err"; then
    fail_from_log "$WORK_DIR/show.err" "terraform show (reconcile plan)"
  fi

  prior="$(jq -c --arg a "$INSTANCE_ADDR" '[.prior_state.values.root_module.resources[]? | select(.address == $a)][0] // empty' "$plan_json")"
  if [[ -z "$prior" ]]; then
    log "The tracked instance no longer exists in OCI (terminated or deleted out-of-band): taking the create path."
    return 0
  fi
  state="$(jq -r '.values.state // ""' <<<"$prior")"
  tainted="$(jq -r '.tainted // false' <<<"$prior")"
  log "Tracked instance state: ${state:-unknown}, tainted: ${tainted}"

  case "$state" in
    TERMINATED)
      log "Tracked instance is TERMINATED: removing it from state and taking the create path."
      tf_logged "$WORK_DIR/state-rm.log" state rm -no-color -lock-timeout="$LOCK_TIMEOUT" "$INSTANCE_ADDR" ||
        fail_from_log "$WORK_DIR/state-rm.log" "terraform state rm"
      return 0
      ;;
    TERMINATING)
      conclude retry terminating "The tracked A1 instance is still TERMINATING." \
        "Once OCI finishes terminating it, the next scheduled run drops it from state and starts creating a new one. Creating now would most likely hit LimitExceeded."
      ;;
  esac

  if [[ "$tainted" == "true" ]]; then
    refuse_destructive "It is tainted but still ${state:-alive}, so a create would replace a live instance; run terraform untaint if it is healthy." \
      "A launch that timed out can leave a tainted instance that later becomes RUNNING. If the instance is healthy, keep it:

\`\`\`sh
$(backend_init_hint)
terraform -chdir=modules/oracle-a1/terraform untaint ${INSTANCE_ADDR}
\`\`\`

If you really want a fresh instance, terminate it in the OCI console instead; the next run then creates a new one." "$plan_log"
  fi

  if ((rc == 0)); then
    log "No changes: the instance is healthy."
    report_done instance_present
  fi

  actions="$(jq -r --arg a "$INSTANCE_ADDR" '[.resource_changes[]? | select(.address == $a) | .change.actions[]] | join(",")' "$plan_json")"
  if [[ ",${actions}," == *",delete,"* ]]; then
    changes="$(jq -r '.resource_changes[]? | select(any(.change.actions[]; . == "delete")) | "- `\(.address)`: \(.change.actions | join(" then "))\(if .action_reason then " (\(.action_reason))" else "" end)"' "$plan_json")"
    refuse_destructive "The plan wants to ${actions//,/ then } ${INSTANCE_ADDR}." \
      "Planned destructive actions:

${changes}

A scheduled run never destroys or replaces a live instance. Revert the configuration change that causes this (for example the subnet, compartment or network settings), or apply it deliberately from your machine after reviewing \`terraform plan\`." "$plan_log"
  fi

  resource_changes="$(jq '[.resource_changes[]? | select(.change.actions != ["no-op"] and .change.actions != ["read"])] | length' "$plan_json")"
  log "Applying non-destructive changes: ${actions:-none to the instance} (${resource_changes} resource change(s))"
  tf_logged "$apply_log" apply -input=false -no-color -lock-timeout="$LOCK_TIMEOUT" "$plan_file" ||
    fail_from_log "$apply_log" "terraform apply (reconcile)"
  if [[ "$resource_changes" == "0" ]]; then
    report_done instance_present
  fi
  report_done instance_updated
}

orphan_guard() {
  local out err="$WORK_DIR/instances.err" rc matches live terminating listing
  log "Orphan guard: looking for untracked ${SHAPE} instances in the target compartment..."
  out="$(oci compute instance list --region "$OCI_REGION" --compartment-id "$COMPARTMENT" --all \
    --max-retries 3 </dev/null 2>"$err")"
  rc=$?
  if ((rc != 0)); then
    cat "$err" >&2
    case "$(classify_log "$err")" in
      throttle) fail_class throttle "orphan guard (listing instances)" "$err" ;;
      auth) fail_class auth "orphan guard (listing instances)" "$err" ;;
      *) conclude fatal error "Orphan guard could not list instances." "Read the log tail below." "$err" ;;
    esac
  fi
  [[ -n "${out//[[:space:]]/}" ]] || out='{}'
  if ! matches="$(jq -c --arg shape "$SHAPE" '[(.data // [])[]? | select(.shape == $shape)
      | {id: .id, name: ."display-name", state: ."lifecycle-state", ad: ."availability-domain"}]' <<<"$out" 2>/dev/null)"; then
    conclude fatal error "Orphan guard could not parse the instance list." "Read the log tail below." "$err"
  fi
  live="$(jq -c '[.[] | select(.state != "TERMINATED" and .state != "TERMINATING")]' <<<"$matches")"
  terminating="$(jq -c '[.[] | select(.state == "TERMINATING")]' <<<"$matches")"

  if [[ "$(jq 'length' <<<"$live")" != "0" ]]; then
    listing="$(jq -r '.[] | "- `\(.id)` \(.name) (\(.state), \(.ad))"' <<<"$live")"
    conclude fatal orphan "Found ${SHAPE} instance(s) that Terraform does not track." \
      "Terraform state has no instance, but the compartment already contains:

${listing}

Creating another would only hit LimitExceeded. Either terminate the instance(s) in the OCI console, or adopt one into state (the same backend settings as the workflow; with a module-created network, import it too):

\`\`\`sh
$(backend_init_hint)
export TF_VAR_tenancy_ocid=<tenancy-ocid> TF_VAR_ssh_public_key='<public key>' TF_VAR_instance_availability_domain='<AD>' \\
  TF_VAR_region=${OCI_REGION} TF_VAR_ocpus=${OCPUS} TF_VAR_memory_in_gbs=${MEMORY_GB} \\
  TF_VAR_compartment_ocid='<OCI_COMPARTMENT_OCID or empty>' TF_VAR_existing_subnet_id='<OCI_SUBNET_OCID or empty>'
terraform -chdir=modules/oracle-a1/terraform import ${INSTANCE_ADDR} <instance-ocid>
# Network OCIDs: oci compute instance list-vnics --instance-id <instance-ocid>  (subnet-id), then oci network subnet get
terraform -chdir=modules/oracle-a1/terraform import 'oci_core_vcn.main[0]' <vcn-ocid>
terraform -chdir=modules/oracle-a1/terraform import 'oci_core_internet_gateway.main[0]' <igw-ocid>
terraform -chdir=modules/oracle-a1/terraform import 'oci_core_route_table.public[0]' <route-table-ocid>
terraform -chdir=modules/oracle-a1/terraform import 'oci_core_security_list.public[0]' <security-list-ocid>
terraform -chdir=modules/oracle-a1/terraform import 'oci_core_subnet.public[0]' <subnet-ocid>
terraform -chdir=modules/oracle-a1/terraform plan   # must show no delete on ${INSTANCE_ADDR}
\`\`\`"
  fi
  if [[ "$(jq 'length' <<<"$terminating")" != "0" ]]; then
    conclude retry terminating "An untracked ${SHAPE} instance is still TERMINATING." \
      "The next scheduled run tries again once OCI finishes terminating it."
  fi
  log "Orphan guard: no untracked ${SHAPE} instances."
}

CAP_RESULT=""
CAP_DETAIL=""
capacity_report() {
  local ad="$1" shapes out err="$WORK_DIR/capacity.err" rc statuses
  shapes="$(jq -cn --argjson o "$OCPUS" --argjson m "$MEMORY_GB" \
    '[{instanceShape: "VM.Standard.A1.Flex", instanceShapeConfig: {ocpus: $o, memoryInGBs: $m}}]')"
  out="$(oci compute compute-capacity-report create --region "$OCI_REGION" \
    --availability-domain "$ad" --compartment-id "$TENANCY_OCID" \
    --shape-availabilities "$shapes" \
    --query 'data."shape-availabilities"[]."availability-status"' \
    --max-retries 2 --connection-timeout 10 --read-timeout 30 </dev/null 2>"$err")"
  rc=$?
  statuses="$(jq -r '.[]? // empty' <<<"${out:-[]}" 2>/dev/null | sort -u | tr '\n' ' ')"
  statuses="${statuses% }"
  if ((rc != 0)); then
    CAP_RESULT="inconclusive"
    log "Capacity report for ${ad}: inconclusive (CLI error, attempting anyway)."
    if [[ "$(classify_log "$err")" == "auth" ]]; then
      warn "Capacity report was not authorised: the policy 'manage compute-capacity-reports in tenancy' is probably missing."
    fi
  elif [[ " $statuses " == *" AVAILABLE "* ]]; then
    CAP_RESULT="available"
    log "Capacity report for ${ad}: AVAILABLE"
  elif [[ -n "$statuses" ]] && ! tr ' ' '\n' <<<"$statuses" | grep -qvxE 'OUT_OF_HOST_CAPACITY|HARDWARE_NOT_SUPPORTED'; then
    CAP_RESULT="skip"
    log "Capacity report for ${ad}: ${statuses} (skipping this AD)"
  else
    CAP_RESULT="inconclusive"
    log "Capacity report for ${ad}: inconclusive ('${statuses:-empty}', attempting anyway)."
  fi
  CAP_DETAIL="${statuses:-no answer}"
}

ATTEMPT_CLASS=""
ATTEMPT_LOG=""
attempt_apply() {
  local ad="$1" fd="$2" rc
  ATTEMPT_NO=$((ATTEMPT_NO + 1))
  ATTEMPT_LOG="$WORK_DIR/attempt-${ATTEMPT_NO}.log"
  log "Attempt ${ATTEMPT_NO}: terraform apply in ${ad}${fd:+ / ${fd}}"
  tf_logged "$ATTEMPT_LOG" apply -input=false -no-color -auto-approve -lock-timeout="$LOCK_TIMEOUT" \
    -var="instance_availability_domain=${ad}" -var="fault_domain=${fd}"
  rc=$?
  if ((rc == 0)); then
    ATTEMPT_CLASS="ok"
  else
    ATTEMPT_CLASS="$(classify_log "$ATTEMPT_LOG")"
  fi
  log "Attempt ${ATTEMPT_NO} result: ${ATTEMPT_CLASS}"
}

create_path() {
  local ad fd placements=("") skipped_all=true
  if [[ "$TRY_FAULT_DOMAINS" == "true" ]]; then
    placements+=("FAULT-DOMAIN-1" "FAULT-DOMAIN-2" "FAULT-DOMAIN-3")
  fi
  orphan_guard

  for ad in "${ADS[@]}"; do
    if [[ "$CAPACITY_CHECK" == "true" ]]; then
      capacity_report "$ad"
      if [[ "$CAP_RESULT" == "skip" ]]; then
        record_attempt "$ad" "" "skipped: capacity report ${CAP_DETAIL}"
        continue
      fi
    fi
    skipped_all=false
    for fd in "${placements[@]}"; do
      if deadline_passed; then
        conclude retry no_capacity "Stopped after ${SECONDS}s (MAX_RUN_SECONDS=${MAX_RUN_SECONDS}) without finding capacity." \
          "The next scheduled run tries again."
      fi
      if ((ATTEMPT_NO > 0 && SLEEP_BETWEEN > 0)); then
        log "Sleeping ${SLEEP_BETWEEN}s before the next attempt."
        sleep "$SLEEP_BETWEEN"
      fi
      attempt_apply "$ad" "$fd"
      case "$ATTEMPT_CLASS" in
        ok)
          record_attempt "$ad" "$fd" "created"
          report_done instance_created
          ;;
        capacity)
          record_attempt "$ad" "$fd" "out of host capacity"
          if instance_in_state; then
            conclude retry no_capacity "The launch failed after OCI accepted it; the failed instance is still recorded in state." \
              "The next scheduled run inspects that record and cleans it up before trying again." "$ATTEMPT_LOG"
          fi
          ;;
        *)
          record_attempt "$ad" "$fd" "${ATTEMPT_CLASS}"
          # An accepted-then-failed launch (e.g. an empty work-request message) recovers on the next run.
          if [[ "$ATTEMPT_CLASS" == "other" ]] && instance_in_state; then
            conclude retry launch_failed "OCI accepted the launch but it failed; the failed instance is still recorded in state." \
              "The next scheduled run inspects that record: a terminated one is cleaned up before trying again, a live one is reported instead of replaced." "$ATTEMPT_LOG"
          fi
          fail_class "$ATTEMPT_CLASS" "terraform apply in ${ad}${fd:+ / ${fd}}" "$ATTEMPT_LOG"
          ;;
      esac
    done
  done

  if [[ "$skipped_all" == "true" ]]; then
    conclude retry no_capacity "Capacity reports show no A1 capacity in any availability domain." \
      "No launch was attempted. The next scheduled run tries again."
  fi
  conclude retry no_capacity "No A1 capacity in any availability domain or placement tried (${ATTEMPT_NO} attempt(s))." \
    "The next scheduled run tries again." "$ATTEMPT_LOG"
}

main() {
  preflight
  discover_ads
  terraform_init
  if instance_in_state; then
    reconcile
  fi
  create_path
}

main "$@"
