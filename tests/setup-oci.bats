#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SETUP_OCI="$REPO_ROOT/.github/actions/setup-oci/setup-oci.sh"
  INSTALL_CLI="$REPO_ROOT/.github/actions/setup-oci/install-oci-cli.sh"

  export HOME="$BATS_TEST_TMPDIR/home"
  export RUNNER_TEMP="$BATS_TEST_TMPDIR/runner-temp"
  STUB_BIN="$BATS_TEST_TMPDIR/stubs"
  mkdir -p "$HOME" "$RUNNER_TEMP" "$STUB_BIN"

  export GITHUB_ACTIONS=true
  export GITHUB_ENV="$BATS_TEST_TMPDIR/github_env"
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/github_output"
  export GITHUB_PATH="$BATS_TEST_TMPDIR/github_path"
  export GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/summary.md"
  : >"$GITHUB_ENV"
  : >"$GITHUB_OUTPUT"
  : >"$GITHUB_PATH"
  : >"$GITHUB_STEP_SUMMARY"

  unset OCI_CLI_CONFIG_FILE SUPPRESS_LABEL_WARNING CLI_VERSION FAKE_OCI
  unset OCI_TENANCY_OCID OCI_USER_OCID OCI_FINGERPRINT OCI_PRIVATE_KEY OCI_REGION

  export OCI_CALLS="$BATS_TEST_TMPDIR/oci.calls"
  export PIPX_CALLS="$BATS_TEST_TMPDIR/pipx.calls"
  export FAKE_PIPX_BIN="$BATS_TEST_TMPDIR/pipx-bin"

  TENANCY="ocid1.tenancy.oc1..aaaaaaaafaketenancy"
  USER_OCID="ocid1.user.oc1..aaaaaaaafakeuser"
  FINGERPRINT="0f:1e:2d:3c:4b:5a:69:78:87:96:a5:b4:c3:d2:e1:f0"
  # Split so that secret scanners do not flag the fixtures as real keys.
  DASHES="-----"
  KEY_LINE_1="FAKEKEYBODYAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
  KEY_LINE_2="FAKEKEYBODYBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=="

  write_oci_stub
  PATH="$STUB_BIN:$(minimal_path)"
}

minimal_path() {
  local dir="$BATS_TEST_TMPDIR/sysbin" tool found
  mkdir -p "$dir"
  for tool in bash env cat grep sed awk tr tail head dirname basename date mkdir chmod rm od \
    sort mktemp readlink timeout jq stat wc cmp ls cp mv touch tee uname sleep kill cut find; do
    if found="$(command -v "$tool")"; then
      ln -sf "$found" "$dir/$tool"
    fi
  done
  printf '%s' "$dir"
}

# Usage: pem LABEL [HEADER_LINE...]
pem() {
  local label="$1" line
  shift
  printf '%sBEGIN %s%s\n' "$DASHES" "$label" "$DASHES"
  for line in "$@"; do
    printf '%s\n' "$line"
  done
  printf '%s\n%s\n' "$KEY_LINE_1" "$KEY_LINE_2"
  printf '%sEND %s%s\n' "$DASHES" "$label" "$DASHES"
}

set_valid_inputs() {
  export OCI_TENANCY_OCID="$TENANCY"
  export OCI_USER_OCID="$USER_OCID"
  export OCI_FINGERPRINT="$FINGERPRINT"
  OCI_PRIVATE_KEY="$(pem "PRIVATE KEY")"
  export OCI_PRIVATE_KEY
}

write_oci_stub() {
  cat >"$STUB_BIN/oci" <<'STUB'
#!/usr/bin/env bash
{
  printf 'CALL'
  printf ' %s' "$@"
  printf '\n'
  printf 'ENV OCI_CLI_CONFIG_FILE=%s SUPPRESS_LABEL_WARNING=%s\n' "${OCI_CLI_CONFIG_FILE:-}" "${SUPPRESS_LABEL_WARNING:-}"
  if [[ -e "/proc/$$/fd/0" ]]; then
    printf 'STDIN %s\n' "$(readlink "/proc/$$/fd/0")"
  fi
} >>"$OCI_CALLS"
case "${FAKE_OCI:-ok}" in
  ok)
    printf '[\n  "Qxyz:AP-SYDNEY-1-AD-1"\n]\n'
    ;;
  empty) ;;
  auth)
    cat >&2 <<'EOF'
ServiceError:
{
    "client_version": "Oracle-PythonSDK/2.187.0, Oracle-PythonCLI/3.94.0",
    "code": "NotAuthenticated",
    "logging_tips": "Please run the OCI CLI command using --debug flag to find more debug information.",
    "message": "The required information to complete authentication was not provided or was incorrect.",
    "opc-request-id": "88D518AB19BB4F40B52C83830E7EB0C2/36240E7AB2F7E90B51E3B56A53594424/7A69C2A1DF16296063426E5EEA8DF5AF",
    "operation_name": "list_availability_domains",
    "request_endpoint": "GET https://identity.ap-sydney-1.oci.oraclecloud.com/20160918/availabilityDomains",
    "status": 401,
    "target_service": "identity",
    "timestamp": "2026-09-25T02:58:25.035582+00:00",
    "troubleshooting_tips": "See [https://docs.oracle.com/iaas/Content/API/References/apierrors.htm] for more information about resolving this error."
}
EOF
    exit 1
    ;;
  notfound)
    cat >&2 <<'EOF'
ServiceError:
{
    "code": "NotAuthorizedOrNotFound",
    "message": "Authorization failed or requested resource not found.",
    "operation_name": "list_availability_domains",
    "status": 404,
    "target_service": "identity"
}
EOF
    exit 1
    ;;
  throttle)
    cat >&2 <<'EOF'
TransientServiceError:
{
    "code": "TooManyRequests",
    "message": "Too many requests for the user",
    "operation_name": "list_availability_domains",
    "status": 429,
    "target_service": "identity"
}
EOF
    exit 1
    ;;
  network)
    cat >&2 <<'EOF'
RequestException:
{
    "client_version": "Oracle-PythonSDK/2.187.0, Oracle-PythonCLI/3.94.0",
    "message": "The connection to endpoint timed out.",
    "target_service": "CLI"
}
EOF
    exit 1
    ;;
esac
exit 0
STUB
  chmod +x "$STUB_BIN/oci"
}

write_pipx_stub() {
  cat >"$STUB_BIN/pipx" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$PIPX_CALLS"
case "$1" in
  list) [[ -z "${FAKE_PIPX_LIST:-}" ]] || printf '%s\n' "$FAKE_PIPX_LIST" ;;
  environment) printf '%s\n' "$FAKE_PIPX_BIN" ;;
  install)
    [[ "${FAKE_PIPX_RC:-0}" == "0" ]] || exit "$FAKE_PIPX_RC"
    mkdir -p "$FAKE_PIPX_BIN"
    printf '#!/usr/bin/env bash\necho "%s"\n' "${FAKE_INSTALLED_VERSION:-3.94.0}" >"$FAKE_PIPX_BIN/oci"
    chmod +x "$FAKE_PIPX_BIN/oci"
    ;;
esac
exit 0
STUB
  chmod +x "$STUB_BIN/pipx"
}

# A bare `! cmd` never fails a bats test (errexit ignores negated commands).
refute_file_contains() {
  if grep -qE -- "$2" "$1"; then
    printf '%s unexpectedly matches %s\n' "$1" "$2" >&2
    return 1
  fi
}

output_without_masks() {
  grep -v '^::add-mask::' <<<"$output" || true
}

mode_of() {
  stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"
}

output_value() {
  sed -n "/^$1<</{n;p;}" "$GITHUB_OUTPUT"
}

# ------------------------------------------------------------ input validation

@test "missing inputs are listed by secret name and values are never printed" {
  export OCI_FINGERPRINT="0F:1E:2D:3C:4B:5A:69:78:87:96:A5:B4:C3:D2:E1:F0"
  run -1 "$SETUP_OCI" configure
  [[ "$output" == *"::error::Missing required secrets: OCI_TENANCY_OCID OCI_USER_OCID OCI_PRIVATE_KEY"* ]]
  [[ "$(output_without_masks)" != *"0F:1E"* ]]
  [[ "$(output_without_masks)" != *"0f:1e"* ]]
  grep -q 'Missing required secrets: OCI_TENANCY_OCID OCI_USER_OCID OCI_PRIVATE_KEY' "$GITHUB_STEP_SUMMARY"
  grep -q '### What to fix' "$GITHUB_STEP_SUMMARY"
  refute_file_contains "$GITHUB_STEP_SUMMARY" '0[fF]:1[eE]'
  [[ ! -e "$HOME/.oci/config" ]]
  [[ ! -e "$OCI_CALLS" ]]
}

@test "whitespace-only secrets count as missing" {
  export OCI_TENANCY_OCID=$'  \r\n' OCI_USER_OCID=" " OCI_FINGERPRINT=$'\t' OCI_PRIVATE_KEY=$'\r\n\r\n'
  run -1 "$SETUP_OCI"
  [[ "$output" == *"Missing required secrets: OCI_TENANCY_OCID OCI_USER_OCID OCI_FINGERPRINT OCI_PRIVATE_KEY"* ]]
  [[ ! -e "$OCI_CALLS" ]]
}

@test "an OpenSSH private key is rejected as an SSH key" {
  set_valid_inputs
  OCI_PRIVATE_KEY="$(pem "OPENSSH PRIVATE KEY")"
  run -1 "$SETUP_OCI"
  [[ "$output" == *"::error::OCI_PRIVATE_KEY is an OpenSSH private key"* ]]
  [[ "$output" == *"this is an SSH key, not an OCI API signing key"* ]]
  [[ "$output" != *"FAKEKEYBODY"* ]]
  [[ ! -e "$HOME/.oci/oci_api_key.pem" ]]
  [[ ! -e "$OCI_CALLS" ]]
}

@test "an encrypted PKCS#8 key is rejected before it can hang on a passphrase prompt" {
  set_valid_inputs
  OCI_PRIVATE_KEY="$(pem "ENCRYPTED PRIVATE KEY")"
  run -1 "$SETUP_OCI"
  [[ "$output" == *"::error::OCI_PRIVATE_KEY is encrypted with a passphrase"* ]]
  [[ "$output" == *"passphrase prompt"* ]]
  [[ ! -e "$HOME/.oci/oci_api_key.pem" ]]
  [[ ! -e "$OCI_CALLS" ]]
}

@test "an encrypted traditional RSA key is rejected" {
  set_valid_inputs
  OCI_PRIVATE_KEY="$(pem "RSA PRIVATE KEY" "Proc-Type: 4,ENCRYPTED" "DEK-Info: AES-128-CBC,00112233445566778899AABBCCDDEEFF" "")"
  run -1 "$SETUP_OCI"
  [[ "$output" == *"OCI_PRIVATE_KEY is encrypted with a passphrase"* ]]
  [[ ! -e "$OCI_CALLS" ]]
}

@test "a PEM public key is rejected" {
  set_valid_inputs
  OCI_PRIVATE_KEY="$(pem "PUBLIC KEY")"
  run -1 "$SETUP_OCI"
  [[ "$output" == *"::error::OCI_PRIVATE_KEY contains a public key"* ]]
  [[ ! -e "$OCI_CALLS" ]]
}

@test "an SSH public key line is rejected as a public key" {
  set_valid_inputs
  export OCI_PRIVATE_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeFakeFakeFakeFakeFakeFakeFakeFake user@host"
  run -1 "$SETUP_OCI"
  [[ "$output" == *"OCI_PRIVATE_KEY contains a public key"* ]]
}

@test "a key pasted onto one line or without an END line is rejected" {
  set_valid_inputs
  export OCI_PRIVATE_KEY="${DASHES}BEGIN PRIVATE KEY${DASHES} ${KEY_LINE_1} ${DASHES}END PRIVATE KEY${DASHES}"
  run -1 "$SETUP_OCI"
  [[ "$output" == *"OCI_PRIVATE_KEY is not a PEM API signing key"* ]]

  OCI_PRIVATE_KEY="$(pem "PRIVATE KEY" | head -n 2)"
  run -1 "$SETUP_OCI"
  [[ "$output" == *"OCI_PRIVATE_KEY is incomplete"* ]]
}

@test "malformed OCIDs and fingerprint are all reported at once" {
  set_valid_inputs
  export OCI_TENANCY_OCID="$USER_OCID" OCI_USER_OCID="$TENANCY" OCI_FINGERPRINT="SHA256:abcdef"
  run -1 "$SETUP_OCI"
  [[ "$output" == *"::error::OCI_TENANCY_OCID must be a tenancy OCID"* ]]
  [[ "$output" == *"::error::OCI_USER_OCID must be a user OCID"* ]]
  [[ "$output" == *"::error::OCI_FINGERPRINT must be the API key fingerprint"* ]]
  [[ "$(output_without_masks)" != *"SHA256:abcdef"* ]]
  [[ "$(output_without_masks)" != *"aaaaaaaafake"* ]]
  [[ ! -e "$OCI_CALLS" ]]
}

@test "an invalid region is rejected" {
  set_valid_inputs
  export OCI_REGION="Sydney"
  run -1 "$SETUP_OCI" configure
  [[ "$output" == *"OCI_REGION must be an OCI region identifier"* ]]
}

# ------------------------------------------------------------ writing the config

@test "an uppercase fingerprint is trimmed, lowercased and masked before any other output" {
  set_valid_inputs
  export OCI_FINGERPRINT=$'  0F:1E:2D:3C:4B:5A:69:78:87:96:A5:B4:C3:D2:E1:F0 \r\n'
  run -0 "$SETUP_OCI" configure
  grep -qx "fingerprint=$FINGERPRINT" "$HOME/.oci/config"
  [[ "${lines[0]}" == ::add-mask::* ]]
  local first_other
  first_other="$(grep -nv '^::add-mask::' <<<"$output" | head -n 1 | cut -d: -f1)"
  local mask_line
  mask_line="$(grep -nx "::add-mask::$FINGERPRINT" <<<"$output" | cut -d: -f1)"
  [[ -n "$mask_line" ]]
  ((mask_line < first_other))
}

@test "config and key are written with mode 600 under HOME and never echoed" {
  set_valid_inputs
  OCI_PRIVATE_KEY=$'\r\n  '"$(pem "PRIVATE KEY" | awk '{ printf "%s\r\n", $0 }')"$'\r\n'
  export OCI_TENANCY_OCID=" $TENANCY"$'\r'
  run -0 "$SETUP_OCI" configure
  [[ "$(mode_of "$HOME/.oci")" == "700" ]]
  [[ "$(mode_of "$HOME/.oci/config")" == "600" ]]
  [[ "$(mode_of "$HOME/.oci/oci_api_key.pem")" == "600" ]]
  cmp "$HOME/.oci/oci_api_key.pem" <(pem "PRIVATE KEY")
  cmp "$HOME/.oci/config" <(printf '[DEFAULT]\nuser=%s\nfingerprint=%s\ntenancy=%s\nregion=%s\nkey_file=%s\n' \
    "$USER_OCID" "$FINGERPRINT" "$TENANCY" "ap-sydney-1" "$HOME/.oci/oci_api_key.pem")
  [[ "$output" != *"FAKEKEYBODY"* ]]
  [[ "$output" != *"[DEFAULT]"* ]]
  [[ "$output" != *"key_file="* ]]
  [[ "$(output_without_masks)" != *"$TENANCY"* ]]
  [[ "$(output_without_masks)" != *"$USER_OCID"* ]]
  refute_file_contains "$GITHUB_STEP_SUMMARY" 'FAKEKEYBODY'
}

@test "an existing config with open permissions is replaced with mode 600" {
  set_valid_inputs
  mkdir -p "$HOME/.oci"
  printf 'old\n' >"$HOME/.oci/config"
  chmod 644 "$HOME/.oci/config"
  run -0 "$SETUP_OCI" configure
  [[ "$(mode_of "$HOME/.oci/config")" == "600" ]]
  refute_file_contains "$HOME/.oci/config" '^old$'
}

@test "GITHUB_ENV gets the config path and the label-warning switch appended" {
  set_valid_inputs
  printf 'EXISTING=1\n' >"$GITHUB_ENV"
  run -0 "$SETUP_OCI" configure
  [[ "$(cat "$GITHUB_ENV")" == "EXISTING=1"$'\n'"OCI_CLI_CONFIG_FILE=$HOME/.oci/config"$'\n'"SUPPRESS_LABEL_WARNING=True" ]]
}

@test "the region input is written to the config and a blank one defaults to ap-sydney-1" {
  set_valid_inputs
  export OCI_REGION="us-ashburn-1"
  run -0 "$SETUP_OCI" configure
  grep -qx 'region=us-ashburn-1' "$HOME/.oci/config"

  export OCI_REGION="  "
  run -0 "$SETUP_OCI" configure
  grep -qx 'region=ap-sydney-1' "$HOME/.oci/config"
}

@test "outside GitHub Actions an existing config is never overwritten" {
  set_valid_inputs
  unset GITHUB_ACTIONS
  mkdir -p "$HOME/.oci"
  printf 'mine\n' >"$HOME/.oci/config"
  run -1 "$SETUP_OCI" configure
  [[ "$output" == *"Refusing to overwrite"* ]]
  [[ "$(cat "$HOME/.oci/config")" == "mine" ]]
}

@test "configure mode never calls the OCI CLI" {
  set_valid_inputs
  run -0 "$SETUP_OCI" configure
  [[ ! -e "$OCI_CALLS" ]]
}

# ------------------------------------------------------------ auth probe

@test "the probe lists availability domains non-interactively with the written config" {
  set_valid_inputs
  run -0 "$SETUP_OCI"
  [[ "$(grep -c '^CALL' "$OCI_CALLS")" == "1" ]]
  local call
  call="$(grep '^CALL' "$OCI_CALLS")"
  [[ "$call" == "CALL iam availability-domain list "* ]]
  [[ "$call" == *" --compartment-id $TENANCY "* ]]
  [[ "$call" == *" --region ap-sydney-1 "* ]]
  [[ "$call" == *" --max-retries 3"* ]]
  grep -qx "ENV OCI_CLI_CONFIG_FILE=$HOME/.oci/config SUPPRESS_LABEL_WARNING=True" "$OCI_CALLS"
  if grep -q '^STDIN' "$OCI_CALLS"; then
    grep -qx 'STDIN /dev/null' "$OCI_CALLS"
  fi
  [[ "$output" == *"OCI authentication OK: 1 availability domain(s) in ap-sydney-1"* ]]
}

@test "probe mode needs only the tenancy and region" {
  set_valid_inputs
  run -0 "$SETUP_OCI" configure
  unset OCI_USER_OCID OCI_FINGERPRINT OCI_PRIVATE_KEY
  export OCI_REGION="ap-sydney-1"
  run -0 "$SETUP_OCI" probe
  grep -q -- "--compartment-id $TENANCY " "$OCI_CALLS"
}

@test "an authentication failure prints the CLI error, fails and says what to fix" {
  set_valid_inputs
  export FAKE_OCI=auth
  run -1 "$SETUP_OCI"
  [[ "$output" == *'"code": "NotAuthenticated"'* ]]
  [[ "$output" == *"::error::OCI rejected the credentials"* ]]
  grep -q '## ❌ setup-oci: OCI authentication failed' "$GITHUB_STEP_SUMMARY"
  grep -q '### What to fix' "$GITHUB_STEP_SUMMARY"
  grep -q 'API signing key' "$GITHUB_STEP_SUMMARY"
  grep -q 'NotAuthenticated' "$GITHUB_STEP_SUMMARY"
  refute_file_contains "$GITHUB_STEP_SUMMARY" 'FAKEKEYBODY'
  [[ "$output" != *"FAKEKEYBODY"* ]]
}

@test "a 404 from the probe points at the inspect compartments policy" {
  set_valid_inputs
  export FAKE_OCI=notfound
  run -1 "$SETUP_OCI"
  grep -q 'inspect compartments in tenancy' "$GITHUB_STEP_SUMMARY"
}

@test "a throttled probe fails without blaming the credentials" {
  set_valid_inputs
  export FAKE_OCI=throttle
  run -1 "$SETUP_OCI"
  [[ "$output" == *"::error::OCI rate limited the authentication probe"* ]]
  grep -q 'Nothing in the configuration' "$GITHUB_STEP_SUMMARY"
}

@test "a network error from the probe is not reported as an auth failure" {
  set_valid_inputs
  export FAKE_OCI=network
  run -1 "$SETUP_OCI"
  [[ "$output" == *"other than rejected credentials"* ]]
  [[ "$output" != *"OCI rejected the credentials"* ]]
  grep -q '### What to fix' "$GITHUB_STEP_SUMMARY"
}

@test "a probe that returns no availability domains fails" {
  set_valid_inputs
  export FAKE_OCI=empty
  run -1 "$SETUP_OCI"
  [[ "$output" == *"returned no availability domains"* ]]
  grep -q 'OCI_REGION' "$GITHUB_STEP_SUMMARY"
}

# ------------------------------------------------------------ OCI CLI install

@test "detect reports pipx=true when pipx is on PATH" {
  write_pipx_stub
  run -0 "$INSTALL_CLI" detect
  [[ "$(output_value pipx)" == "true" ]]
}

@test "detect reports pipx=false when pipx is missing" {
  run -0 "$INSTALL_CLI" detect
  [[ "$(output_value pipx)" == "false" ]]
}

@test "install uses pipx with the pinned version and publishes its bin dir" {
  rm -f "$STUB_BIN/oci"
  write_pipx_stub
  run -0 "$INSTALL_CLI" install
  grep -qx 'install oci-cli==3.94.0' "$PIPX_CALLS"
  grep -qx "$FAKE_PIPX_BIN" "$GITHUB_PATH"
  [[ "$output" == *"OCI CLI 3.94.0 installed"* ]]
}

@test "install forces pipx only when another oci-cli version is already installed" {
  rm -f "$STUB_BIN/oci"
  write_pipx_stub
  export FAKE_PIPX_LIST="oci-cli 3.90.0"
  run -0 "$INSTALL_CLI" install
  grep -qx 'install --force oci-cli==3.94.0' "$PIPX_CALLS"
}

@test "install honours the oci-cli-version input" {
  rm -f "$STUB_BIN/oci"
  write_pipx_stub
  export CLI_VERSION="3.95.1" FAKE_INSTALLED_VERSION="3.95.1"
  run -0 "$INSTALL_CLI" install
  grep -qx 'install oci-cli==3.95.1' "$PIPX_CALLS"
}

@test "install fails when the installed CLI does not report the pinned version" {
  rm -f "$STUB_BIN/oci"
  write_pipx_stub
  export FAKE_INSTALLED_VERSION="3.93.0"
  run -1 "$INSTALL_CLI" install
  [[ "$output" == *"::error::Expected OCI CLI 3.94.0 after installation"*"3.93.0"* ]]
}

@test "install fails loudly when pipx install fails" {
  rm -f "$STUB_BIN/oci"
  write_pipx_stub
  export FAKE_PIPX_RC=1
  run -1 "$INSTALL_CLI" install
  [[ "$output" == *"::error::pipx install oci-cli==3.94.0 failed."* ]]
  grep -q 'OCI CLI installation failed' "$GITHUB_STEP_SUMMARY"
}

@test "install skips pipx when the pinned CLI is already on PATH" {
  write_pipx_stub
  printf '#!/usr/bin/env bash\necho 3.94.0\n' >"$STUB_BIN/oci"
  run -0 "$INSTALL_CLI" install
  [[ ! -e "$PIPX_CALLS" ]]
}

@test "install rejects a version that is not an exact release" {
  rm -f "$STUB_BIN/oci"
  write_pipx_stub
  export CLI_VERSION="3.94.0 --index-url=https://example.invalid"
  run -1 "$INSTALL_CLI" install
  [[ "$output" == *"oci-cli-version must be an exact version"* ]]
  [[ ! -e "$PIPX_CALLS" ]]
}

@test "without pipx, install falls back to python -m pip" {
  rm -f "$STUB_BIN/oci"
  export PY_CALLS="$BATS_TEST_TMPDIR/python.calls" PY_SCRIPTS="$BATS_TEST_TMPDIR/py-scripts"
  cat >"$STUB_BIN/python3" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$PY_CALLS"
if [[ "$1" == "-c" ]]; then
  printf '%s\n' "$PY_SCRIPTS"
elif [[ "$1 $2 $3" == "-m pip install" ]]; then
  mkdir -p "$PY_SCRIPTS"
  printf '#!/usr/bin/env bash\necho 3.94.0\n' >"$PY_SCRIPTS/oci"
  chmod +x "$PY_SCRIPTS/oci"
fi
STUB
  chmod +x "$STUB_BIN/python3"
  run -0 "$INSTALL_CLI" install
  grep -q -- '-m pip install .*oci-cli==3.94.0' "$PY_CALLS"
  grep -qx "$PY_SCRIPTS" "$GITHUB_PATH"
}
