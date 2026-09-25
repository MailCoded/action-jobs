#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# Usage: setup-oci.sh [configure|probe|all]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HUB_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
# shellcheck source=../../../lib/common.sh
source "$HUB_ROOT/lib/common.sh"
CLASSIFY_LIB="$HUB_ROOT/modules/oracle-a1/lib/classify.sh"
if [[ -r "$CLASSIFY_LIB" ]]; then
  # shellcheck source=../../../modules/oracle-a1/lib/classify.sh
  source "$CLASSIFY_LIB"
fi

readonly DEFAULT_REGION="ap-sydney-1"
readonly SECRETS_HINT="Add or correct them under **Settings → Secrets and variables → Actions**. Values are never printed."

TENANCY=""
USER_OCID=""
FINGERPRINT=""
REGION=""
KEY=""

error() {
  if in_actions; then
    annotate error "$*"
  else
    log "ERROR: $*"
  fi
}

trim() {
  local s="${1//$'\r'/}"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

normalize_key() {
  local line out=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    out+=("$line")
  done <<<"${1//$'\r'/}"
  ((${#out[@]} > 0)) || return 0
  trim "$(printf '%s\n' "${out[@]}")"
}

normalize_inputs() {
  TENANCY="$(trim "${OCI_TENANCY_OCID:-}")"
  USER_OCID="$(trim "${OCI_USER_OCID:-}")"
  FINGERPRINT="$(trim "${OCI_FINGERPRINT:-}")"
  FINGERPRINT="${FINGERPRINT,,}"
  REGION="$(trim "${OCI_REGION:-}")"
  REGION="${REGION:-$DEFAULT_REGION}"
  KEY="$(normalize_key "${OCI_PRIVATE_KEY:-}")"
}

mask_derived() {
  local value
  for value in "$TENANCY" "$USER_OCID" "$FINGERPRINT"; do
    if [[ -n "$value" ]]; then
      mask "$value"
    fi
  done
}

key_problem() {
  local key="$1" first
  first="${key%%$'\n'*}"
  if [[ "$key" == *"BEGIN OPENSSH PRIVATE KEY"* ]]; then
    printf '%s' "OCI_PRIVATE_KEY is an OpenSSH private key (BEGIN OPENSSH PRIVATE KEY): this is an SSH key, not an OCI API signing key. In the OCI Console open the automation user, add an API key, download its private key (.pem) and store that file's full contents instead."
  elif [[ "$key" == *"BEGIN ENCRYPTED PRIVATE KEY"* || "$key" =~ Proc-Type:[[:space:]]*4,ENCRYPTED ]]; then
    printf '%s' "OCI_PRIVATE_KEY is encrypted with a passphrase, which would make the OCI CLI hang on a passphrase prompt. Store an unencrypted copy instead, for example: openssl pkey -in encrypted.pem -out oci_api_key.pem"
  elif grep -qE '^-----BEGIN (RSA )?PRIVATE KEY-----$' <<<"$key"; then
    if ! grep -qE '^-----END (RSA )?PRIVATE KEY-----$' <<<"$key"; then
      printf '%s' "OCI_PRIVATE_KEY is incomplete: the END PRIVATE KEY line is missing. Paste the whole .pem file."
    fi
  elif [[ "$key" == *"PUBLIC KEY-----"* || "$first" =~ ^(ssh-(rsa|ed25519|dss)|ecdsa-sha2-)[^[:space:]]*[[:space:]] ]]; then
    printf '%s' "OCI_PRIVATE_KEY contains a public key. Store the private half of the API signing key (the .pem file you kept, starting with a BEGIN PRIVATE KEY line); the public half is what gets uploaded to OCI."
  else
    printf '%s' "OCI_PRIVATE_KEY is not a PEM API signing key. It must be the full contents of the RSA private key file: a BEGIN PRIVATE KEY (or BEGIN RSA PRIVATE KEY) line, the base64 body and the matching END line, each on its own line."
  fi
}

# Usage: fail_config HEADLINE PROBLEM...
fail_config() {
  local headline="$1" problem
  shift
  for problem in "$@"; do
    error "$problem"
  done
  summary_line "## ❌ setup-oci: ${headline}"
  summary_line ""
  summary_line "### What to fix"
  summary_line ""
  for problem in "$@"; do
    summary_line "- ${problem}"
  done
  summary_line ""
  summary_line "$SECRETS_HINT"
  summary_line ""
  exit 1
}

validate_region() {
  [[ "$REGION" =~ ^[a-z]+(-[a-z]+)+-[0-9]+$ ]] && return 0
  printf '%s' "OCI_REGION must be an OCI region identifier such as ap-sydney-1 (got '${REGION}')."
}

validate_tenancy() {
  [[ -z "$TENANCY" || "$TENANCY" =~ ^ocid1\.tenancy\.[[:alnum:]._-]+$ ]] && return 0
  printf '%s' "OCI_TENANCY_OCID must be a tenancy OCID (it starts with ocid1.tenancy.)."
}

validate_configure_inputs() {
  local missing=() problems=() problem
  [[ -n "$TENANCY" ]] || missing+=(OCI_TENANCY_OCID)
  [[ -n "$USER_OCID" ]] || missing+=(OCI_USER_OCID)
  [[ -n "$FINGERPRINT" ]] || missing+=(OCI_FINGERPRINT)
  [[ -n "$KEY" ]] || missing+=(OCI_PRIVATE_KEY)
  if ((${#missing[@]} > 0)); then
    problems+=("Missing required secrets: ${missing[*]}")
  fi

  problem="$(validate_tenancy)"
  [[ -z "$problem" ]] || problems+=("$problem")
  if [[ -n "$USER_OCID" && ! "$USER_OCID" =~ ^ocid1\.user\.[[:alnum:]._-]+$ ]]; then
    problems+=("OCI_USER_OCID must be a user OCID (it starts with ocid1.user.).")
  fi
  if [[ -n "$FINGERPRINT" && ! "$FINGERPRINT" =~ ^([0-9a-f]{2}:){15}[0-9a-f]{2}$ ]]; then
    problems+=("OCI_FINGERPRINT must be the API key fingerprint shown in the OCI Console: 16 hex pairs separated by colons (aa:bb:...:ff).")
  fi
  if [[ -n "$KEY" ]]; then
    problem="$(key_problem "$KEY")"
    [[ -z "$problem" ]] || problems+=("$problem")
  fi
  problem="$(validate_region)"
  [[ -z "$problem" ]] || problems+=("$problem")

  if ((${#problems[@]} > 0)); then
    fail_config "missing or invalid OCI credentials" "${problems[@]}"
  fi
}

configure() {
  local dir="$HOME/.oci" cfg key_file
  cfg="$dir/config"
  key_file="$dir/oci_api_key.pem"
  validate_configure_inputs

  if ! in_actions && [[ -e "$cfg" ]]; then
    error "Refusing to overwrite ${cfg} outside GitHub Actions."
    exit 1
  fi

  umask 077
  if ! mkdir -p "$dir" || ! chmod 700 "$dir"; then
    error "Could not create ${dir}."
    exit 1
  fi
  rm -f "$cfg" "$key_file"
  if ! printf '%s\n' "$KEY" >"$key_file"; then
    error "Could not write the API key to ${key_file}."
    exit 1
  fi
  if ! {
    printf '[DEFAULT]\n'
    printf 'user=%s\n' "$USER_OCID"
    printf 'fingerprint=%s\n' "$FINGERPRINT"
    printf 'tenancy=%s\n' "$TENANCY"
    printf 'region=%s\n' "$REGION"
    printf 'key_file=%s\n' "$key_file"
  } >"$cfg"; then
    error "Could not write ${cfg}."
    exit 1
  fi
  chmod 600 "$cfg" "$key_file"

  export OCI_CLI_CONFIG_FILE="$cfg" SUPPRESS_LABEL_WARNING=True
  if [[ -n "${GITHUB_ENV:-}" ]]; then
    printf 'OCI_CLI_CONFIG_FILE=%s\nSUPPRESS_LABEL_WARNING=True\n' "$cfg" >>"$GITHUB_ENV"
  fi
  log "Wrote the OCI CLI config (profile DEFAULT, region ${REGION}) and API key under ${dir}, both mode 600."
}

auth_fix_list() {
  local not_found="$1"
  if [[ "$not_found" == "true" ]]; then
    printf '%s\n' "1. OCI accepted the API key, but the user may not list availability domains: the root compartment needs \`Allow group freebie-hub-automation to inspect compartments in tenancy\` (use your group's name; see \`bootstrap/oracle/iam-policy.txt\`)."
  else
    printf '%s\n' "1. \`OCI_PRIVATE_KEY\` is the API signing key of the automation user (not an SSH key), and \`OCI_FINGERPRINT\` is the fingerprint listed next to that key under the user's API keys."
  fi
  cat <<'EOF'
2. `OCI_USER_OCID` and `OCI_TENANCY_OCID` belong to the same tenancy and are not swapped.
3. The `OCI_REGION` variable names a region the tenancy is subscribed to; Always Free A1 needs the **home** region (`modules/oracle-a1/scripts/check-home-region.sh`).
4. A freshly added API key can take a minute or two to start working; re-run the workflow once.
EOF
}

probe_failed() {
  local errfile="$1" class="other" not_found=false
  if declare -F classify_log >/dev/null; then
    class="$(classify_log "$errfile")"
  fi
  if grep -qE 'NotAuthorizedOrNotFound|"status": ?404([^0-9]|$)' "$errfile"; then
    not_found=true
  fi

  case "$class" in
    throttle)
      error "OCI rate limited the authentication probe (TooManyRequests). The credentials were not rejected."
      summary_line "## ❌ setup-oci: OCI rate limited the authentication probe"
      summary_line ""
      summary_line "### What to fix"
      summary_line ""
      summary_line "Nothing in the configuration. OCI answered TooManyRequests while listing availability domains in \`${REGION}\`; the next scheduled run tries again. Investigate only if this repeats for hours."
      ;;
    auth)
      error "OCI rejected the credentials: listing availability domains in ${REGION} failed. See the job summary for what to fix."
      summary_line "## ❌ setup-oci: OCI authentication failed"
      summary_line ""
      summary_line "The OCI CLI could not list availability domains in \`${REGION}\` with the configured API key."
      summary_line ""
      summary_line "### What to fix"
      summary_line ""
      summary_line "$(auth_fix_list "$not_found")"
      summary_line ""
      summary_line "$SECRETS_HINT"
      ;;
    *)
      error "The OCI authentication probe failed for a reason other than rejected credentials (network or OCI service problem). Read the OCI CLI error above."
      summary_line "## ❌ setup-oci: OCI authentication probe failed"
      summary_line ""
      summary_line "### What to fix"
      summary_line ""
      summary_line "The OCI CLI error below is not an authentication error; it usually means OCI or the network was unavailable. Re-run the workflow. If it keeps failing, check the \`OCI_REGION\` variable and the items below."
      summary_line ""
      summary_line "$(auth_fix_list "$not_found")"
      ;;
  esac
  summary_line ""
  summary_details "OCI CLI error" "$errfile" 40
  exit 1
}

probe() {
  local cfg="${OCI_CLI_CONFIG_FILE:-$HOME/.oci/config}" out errfile rc problem ads=()
  if [[ -z "$TENANCY" ]]; then
    fail_config "missing OCI credentials" "Missing required secrets: OCI_TENANCY_OCID"
  fi
  problem="$(validate_tenancy)"
  [[ -z "$problem" ]] || fail_config "invalid OCI credentials" "$problem"
  problem="$(validate_region)"
  [[ -z "$problem" ]] || fail_config "invalid OCI region" "$problem"
  if [[ ! -r "$cfg" ]]; then
    error "OCI CLI config not found at ${cfg}; the configure step must run first."
    exit 1
  fi
  if ! command -v oci >/dev/null 2>&1; then
    error "The oci command is not on PATH; the OCI CLI install step must run first."
    exit 1
  fi

  export SUPPRESS_LABEL_WARNING=True
  errfile="$(mktemp "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/setup-oci-probe.XXXXXX")" || {
    error "Could not create a temporary file."
    exit 1
  }
  log "Checking OCI authentication: listing availability domains in ${REGION}..."
  out="$(oci iam availability-domain list --config-file "$cfg" --compartment-id "$TENANCY" \
    --region "$REGION" --query 'data[].name' --max-retries 3 </dev/null 2>"$errfile")"
  rc=$?
  if ((rc != 0)); then
    log "OCI CLI error (exit ${rc}):"
    cat "$errfile" >&2
    probe_failed "$errfile"
  fi

  rm -f "$errfile"
  if ! command -v jq >/dev/null 2>&1; then
    log "OCI authentication OK (${REGION})."
    return 0
  fi
  mapfile -t ads < <(jq -r '.[]? // empty' <<<"${out:-[]}" 2>/dev/null)
  if ((${#ads[@]} == 0)); then
    error "OCI accepted the credentials but returned no availability domains for ${REGION}."
    summary_line "## ❌ setup-oci: no availability domains in ${REGION}"
    summary_line ""
    summary_line "### What to fix"
    summary_line ""
    summary_line "Set the \`OCI_REGION\` variable to a region the tenancy is subscribed to (for Always Free A1, the home region)."
    summary_line ""
    exit 1
  fi
  log "OCI authentication OK: ${#ads[@]} availability domain(s) in ${REGION}: ${ads[*]}"
}

main() {
  local mode="${1:-all}"
  case "$mode" in
    configure | probe | all) ;;
    *)
      error "Unknown mode '${mode}' (expected configure, probe or all)."
      exit 1
      ;;
  esac
  normalize_inputs
  mask_derived
  case "$mode" in
    configure) configure ;;
    probe) probe ;;
    all)
      configure
      probe
      ;;
  esac
}

main "$@"
