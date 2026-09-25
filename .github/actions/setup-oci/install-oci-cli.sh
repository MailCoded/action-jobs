#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# Usage: install-oci-cli.sh detect|install
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../../lib/common.sh
source "$SCRIPT_DIR/../../../lib/common.sh"

VERSION="${CLI_VERSION:-3.94.0}"

error() {
  if in_actions; then
    annotate error "$*"
  else
    log "ERROR: $*"
  fi
}

fail_install() {
  error "$1"
  summary_line "## ❌ setup-oci: OCI CLI installation failed"
  summary_line ""
  summary_line "$1"
  summary_line ""
  summary_line "This is usually a transient PyPI or network problem: re-run the workflow. The step log shows the installer output."
  summary_line ""
  exit 1
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

add_to_path() {
  local dir="$1"
  [[ -n "$dir" && -d "$dir" ]] || return 0
  PATH="$dir:$PATH"
  if [[ -n "${GITHUB_PATH:-}" ]]; then
    printf '%s\n' "$dir" >>"$GITHUB_PATH"
  fi
}

current_version() {
  command -v oci >/dev/null 2>&1 || return 0
  oci --version 2>/dev/null | tail -n 1 | tr -d '[:space:]'
}

pipx_version_of() {
  pipx list --short 2>/dev/null | awk -v pkg="$1" '$1 == pkg { print $2; exit }'
}

detect() {
  if command -v pipx >/dev/null 2>&1; then
    log "pipx is available: the OCI CLI will be installed with pipx."
    emit pipx true
  else
    log "pipx is not available: falling back to actions/setup-python and pip."
    emit pipx false
  fi
}

install_with_pipx() {
  local installed args=(install)
  installed="$(pipx_version_of oci-cli)"
  if [[ "$installed" != "$VERSION" ]]; then
    [[ -z "$installed" ]] || args+=(--force)
    log "Installing oci-cli==${VERSION} with pipx..."
    with_timeout 600 pipx "${args[@]}" "oci-cli==${VERSION}" </dev/null ||
      fail_install "pipx install oci-cli==${VERSION} failed."
  fi
  add_to_path "$(pipx environment --value PIPX_BIN_DIR 2>/dev/null)"
}

install_with_pip() {
  local python
  python="$(command -v python3 || command -v python)" ||
    fail_install "Neither pipx nor Python is available to install the OCI CLI."
  log "Installing oci-cli==${VERSION} with ${python} -m pip..."
  with_timeout 600 "$python" -m pip install --disable-pip-version-check --progress-bar off "oci-cli==${VERSION}" </dev/null ||
    fail_install "pip install oci-cli==${VERSION} failed."
  add_to_path "$("$python" -c 'import sysconfig; print(sysconfig.get_path("scripts"))' 2>/dev/null)"
}

install_cli() {
  local found
  if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    error "oci-cli-version must be an exact version such as 3.94.0 (got '${VERSION}')."
    exit 1
  fi
  found="$(current_version)"
  if [[ "$found" == "$VERSION" ]]; then
    log "OCI CLI ${VERSION} is already installed at $(command -v oci)."
    return 0
  fi
  if command -v pipx >/dev/null 2>&1; then
    install_with_pipx
  else
    install_with_pip
  fi
  found="$(current_version)"
  if [[ "$found" != "$VERSION" ]]; then
    fail_install "Expected OCI CLI ${VERSION} after installation, but 'oci --version' reports '${found:-nothing}'."
  fi
  log "OCI CLI ${found} installed at $(command -v oci)."
}

case "${1:-}" in
  detect) detect ;;
  install) install_cli ;;
  *)
    error "Usage: install-oci-cli.sh detect|install"
    exit 1
    ;;
esac
