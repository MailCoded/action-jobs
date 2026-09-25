#!/usr/bin/env bash
set -uo pipefail

readonly SHAPE="VM.Standard.A1.Flex"
readonly WORKFLOW_DEFAULT_REGION="ap-sydney-1"

TENANCY_OCID="${TENANCY_OCID:-}"
OCPUS="${OCPUS:-2}"
MEMORY_GB="${MEMORY_GB:-12}"
OCI_REGION="${OCI_REGION:-}"
export SUPPRESS_LABEL_WARNING="${SUPPRESS_LABEL_WARNING:-True}"

WORK_DIR=""
HOME_REGION=""
ADS=()
AD_PROBLEM=""
N_AVAILABLE=0
N_NO_CAPACITY=0
N_NOT_SUPPORTED=0
N_INCONCLUSIVE=0

usage() {
  cat <<'EOF'
Show the tenancy's subscribed regions, its home region, the home region's availability domains
and a compute capacity report per AD, then say where a free A1 instance is possible.

Usage:
  TENANCY_OCID=ocid1.tenancy.oc1..xxxx modules/oracle-a1/scripts/check-home-region.sh

Environment:
  TENANCY_OCID     required
  OCPUS            OCPUs for the capacity probe (default: 2)
  MEMORY_GB        memory in GB for the capacity probe (default: 12)
  OCI_REGION       the region you plan to use; a warning is printed if it is not the home region
  OCI_CLI_PROFILE  OCI CLI profile to use; listing regions needs 'inspect tenancies', so use an admin profile

Exit status: 0 home region found (read the verdict), 1 it could not be determined.
EOF
}

say() {
  printf '%s\n' "$*"
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  [[ -n "$WORK_DIR" ]] && rm -rf "$WORK_DIR"
}

oci_cli() {
  if [[ -n "${OCI_CLI_PROFILE:-}" ]]; then
    oci --profile "$OCI_CLI_PROFILE" "$@" </dev/null
  else
    oci "$@" </dev/null
  fi
}

show_err() {
  [[ -s "$1" ]] && sed 's/^/  /' "$1" >&2
  return 0
}

err_has() {
  grep -qE -- "$2" "$1" 2>/dev/null
}

err_code() {
  local code
  code="$(sed -nE 's/.*"code": ?"([^"]+)".*/\1/p' "$1" 2>/dev/null | head -n1)"
  printf '%s' "${code:-see the error above}"
}

list_regions() {
  local out err="$WORK_DIR/regions.err"
  if ! out="$(oci_cli iam region-subscription list --tenancy-id "$TENANCY_OCID" --all 2>"$err")"; then
    show_err "$err"
    if err_has "$err" '"status": ?404|NotAuthorizedOrNotFound'; then
      die "Listing region subscriptions returned 404 (NotAuthorizedOrNotFound): run with an admin profile, e.g. OCI_CLI_PROFILE=admin (needs 'inspect tenancies in tenancy')."
    elif err_has "$err" '"status": ?401|NotAuthenticated'; then
      die "OCI rejected the API key (401 NotAuthenticated). Check the profile's user, tenancy, fingerprint and key_file."
    fi
    die "Could not list region subscriptions."
  fi

  [[ -n "$out" ]] || out='{}'
  if ! jq -e '(.data // []) | length > 0' >/dev/null 2>&1 <<<"$out"; then
    die "No region subscriptions were returned for ${TENANCY_OCID}."
  fi

  say "Subscribed regions:"
  printf '  %-22s %-5s %-12s %s\n' "REGION" "KEY" "STATUS" "HOME"
  jq -r '.data[] | [."region-name", ."region-key", .status, (if ."is-home-region" then "yes" else "-" end)] | @tsv' <<<"$out" |
    while IFS=$'\t' read -r name key status home; do
      printf '  %-22s %-5s %-12s %s\n' "$name" "$key" "$status" "$home"
    done
  say ""

  HOME_REGION="$(jq -r '[.data[] | select(."is-home-region" == true) | ."region-name"][0] // empty' <<<"$out")"
  [[ -n "$HOME_REGION" ]] || die "None of the subscribed regions is marked as the home region."
  say "Home region: ${HOME_REGION}"
  say ""
}

list_ads() {
  local out err="$WORK_DIR/ads.err" ad
  if ! out="$(oci_cli iam availability-domain list --region "$HOME_REGION" --compartment-id "$TENANCY_OCID" \
    --query 'data[].name' 2>"$err")"; then
    show_err "$err"
    AD_PROBLEM="could not list availability domains ($(err_code "$err")); the profile needs 'inspect compartments in tenancy'"
    say "Availability domains in ${HOME_REGION}: unknown (see the error above)."
    say ""
    return 0
  fi
  while IFS= read -r ad; do
    [[ -n "$ad" ]] && ADS+=("$ad")
  done < <(jq -r '.[]? // empty' 2>/dev/null <<<"${out:-[]}")
  if ((${#ADS[@]} == 0)); then
    AD_PROBLEM="no availability domains were returned"
    say "Availability domains in ${HOME_REGION}: none returned."
    say ""
    return 0
  fi
  say "Availability domains in ${HOME_REGION}:"
  printf '  %s\n' "${ADS[@]}"
  say ""
}

probe_ad() {
  local ad="$1" shapes out err="$WORK_DIR/capacity.err" statuses result
  shapes="$(jq -cn --argjson o "$OCPUS" --argjson m "$MEMORY_GB" \
    '[{instanceShape: "VM.Standard.A1.Flex", instanceShapeConfig: {ocpus: $o, memoryInGBs: $m}}]')"
  if ! out="$(oci_cli compute compute-capacity-report create --region "$HOME_REGION" \
    --availability-domain "$ad" --compartment-id "$TENANCY_OCID" \
    --shape-availabilities "$shapes" \
    --query 'data."shape-availabilities"[]."availability-status"' \
    --max-retries 2 --connection-timeout 10 --read-timeout 30 2>"$err")"; then
    N_INCONCLUSIVE=$((N_INCONCLUSIVE + 1))
    if err_has "$err" '"status": ?404|NotAuthorizedOrNotFound'; then
      result="not authorised (needs 'manage compute-capacity-reports in tenancy')"
    elif err_has "$err" '"status": ?429|TooManyRequests'; then
      result="throttled by OCI; try again in a few minutes"
    else
      show_err "$err"
      result="error ($(err_code "$err"))"
    fi
    printf '  %-40s %s\n' "$ad" "$result"
    return 0
  fi

  statuses="$(jq -r '.[]? // empty' 2>/dev/null <<<"${out:-[]}" | sort -u | tr '\n' ' ')"
  statuses="${statuses% }"
  if [[ " $statuses " == *" AVAILABLE "* ]]; then
    N_AVAILABLE=$((N_AVAILABLE + 1))
    result="AVAILABLE"
  elif [[ "$statuses" == "HARDWARE_NOT_SUPPORTED" ]]; then
    N_NOT_SUPPORTED=$((N_NOT_SUPPORTED + 1))
    result="HARDWARE_NOT_SUPPORTED (A1 is not offered in this AD)"
  elif [[ -n "$statuses" ]] && ! tr ' ' '\n' <<<"$statuses" | grep -qvxE 'OUT_OF_HOST_CAPACITY|HARDWARE_NOT_SUPPORTED'; then
    N_NO_CAPACITY=$((N_NO_CAPACITY + 1))
    result="${statuses// /, }"
  else
    N_INCONCLUSIVE=$((N_INCONCLUSIVE + 1))
    result="inconclusive ('${statuses:-empty}')"
  fi
  printf '  %-40s %s\n' "$ad" "$result"
}

verdict() {
  say "Verdict"
  say "  Always Free A1 instances can only be launched in the tenancy's home region, which cannot be changed."
  say "  Free A1 is possible only in ${HOME_REGION}."
  if [[ -n "$OCI_REGION" && "$OCI_REGION" != "$HOME_REGION" ]]; then
    say "  WARNING: OCI_REGION=${OCI_REGION} is not the home region. Set the repository variable OCI_REGION to ${HOME_REGION}."
  elif [[ -n "$OCI_REGION" ]]; then
    say "  OCI_REGION=${OCI_REGION} matches the home region."
  elif [[ "$HOME_REGION" == "$WORKFLOW_DEFAULT_REGION" ]]; then
    say "  The workflow's default region (${WORKFLOW_DEFAULT_REGION}) is the home region; OCI_REGION can stay unset."
  else
    say "  The workflow defaults to ${WORKFLOW_DEFAULT_REGION}: set the repository variable OCI_REGION to ${HOME_REGION}."
  fi

  if [[ -n "$AD_PROBLEM" ]]; then
    say "  Capacity was not checked: ${AD_PROBLEM}."
  elif ((N_AVAILABLE > 0)); then
    say "  Capacity report: AVAILABLE in ${N_AVAILABLE} of ${#ADS[@]} AD(s) for ${OCPUS} OCPU / ${MEMORY_GB} GB right now. It is a snapshot; only a launch proves it."
  elif ((N_NOT_SUPPORTED == ${#ADS[@]})); then
    say "  Capacity report: ${SHAPE} is not supported in any AD of ${HOME_REGION}."
  elif ((N_NO_CAPACITY > 0 && N_INCONCLUSIVE == 0)); then
    say "  Capacity report: no A1 capacity right now. That is normal; the scheduled workflow keeps retrying."
  else
    say "  Capacity report: inconclusive (see above). The workflow attempts a launch anyway."
  fi
}

main() {
  local problems=() cmd ad
  if (($# > 0)); then
    usage
    [[ "$1" == "-h" || "$1" == "--help" ]] && exit 0
    exit 1
  fi

  [[ "$TENANCY_OCID" =~ ^ocid1\.tenancy\. ]] || problems+=("TENANCY_OCID must be set to the tenancy OCID (ocid1.tenancy...)")
  [[ "$OCPUS" =~ ^[1-9][0-9]*$ ]] || problems+=("OCPUS must be a whole number (got '${OCPUS}')")
  [[ "$MEMORY_GB" =~ ^[1-9][0-9]*$ ]] || problems+=("MEMORY_GB must be a whole number (got '${MEMORY_GB}')")
  if ((${#problems[@]} > 0)); then
    printf 'ERROR: %s\n' "${problems[@]}" >&2
    printf '\n' >&2
    usage >&2
    exit 1
  fi
  for cmd in oci jq; do
    command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: ${cmd}"
  done

  WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/check-home-region.XXXXXX")" || die "Could not create a temporary directory."
  trap cleanup EXIT

  say "OCI CLI profile: ${OCI_CLI_PROFILE:-DEFAULT}"
  say ""
  list_regions
  list_ads

  if ((${#ADS[@]} > 0)); then
    say "Capacity report per AD for ${SHAPE}, ${OCPUS} OCPU / ${MEMORY_GB} GB:"
    for ad in "${ADS[@]}"; do
      probe_ad "$ad"
    done
    say ""
  fi
  if ((OCPUS > 2 || MEMORY_GB > 12)); then
    say "Note: ${OCPUS} OCPU / ${MEMORY_GB} GB exceeds the Always Free A1 allowance of 2 OCPU / 12 GB."
    say ""
  fi

  verdict
}

main "$@"
