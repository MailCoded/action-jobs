#!/usr/bin/env bash
# shellcheck shell=bash

_CLASSIFY_LIMIT_RE='LimitExceeded|service limits? (was|were) exceeded|QuotaExceeded|standard-a1-(core|memory)(-regional)?-count'
_CLASSIFY_LOCK_HEAD_RE='Error acquiring the state lock|failed to lock oci state'
# The heading alone also covers non-contention failures of the lock PUT (e.g. missing policy).
_CLASSIFY_LOCK_PROOF_RE='IfNoneMatchFailed|Lock Info:'
_CLASSIFY_AUTH_RE='NotAuthenticated|NotAuthorizedOrNotFound|BucketNotFound|(^|[^[:alnum:]-])40[13]-[[:alpha:]]+,|Http Status Code: ?40[13]([^0-9]|$)|"status": ?40[13]([^0-9]|$)|The provided key is not a private key|can not create client, bad configuration|did not find a proper configuration for|can not read PrivateKey|failed to parse private key|private key password is required|configuration file did not contain profile|can not read config file|config file at [^ ]+ is invalid|Config file [^ ]+ is invalid|Could not find config file'
_CLASSIFY_CAPACITY_RE='Out of host capacity|Out of capacity for shape|OutOfCapacity|InternalError.{0,160}capacity'
_CLASSIFY_THROTTLE_RE='TooManyRequests|(^|[^[:alnum:]-])429-[[:alpha:]]+,|Http Status Code: ?429([^0-9]|$)|"status": ?429([^0-9]|$)'

# Terraform wraps diagnostic detail at 78 columns and colours output even when piped,
# so phrases are matched on a single de-coloured, whitespace-collapsed line.
_classify_normalize() {
  local esc=$'\033'
  sed -e "s/${esc}\[[0-9;]*[A-Za-z]//g" -e 's/│/ /g' -e 's/╷/ /g' -e 's/╵/ /g' "$1" |
    tr '\r\n\t' '   ' | tr -s ' '
}

_classify_match() {
  grep -qiE -- "$2" <<<"$1"
}

classify_log() {
  local file="${1:-}" text
  if [[ -z "$file" || ! -r "$file" ]]; then
    printf 'other\n'
    return 0
  fi
  text="$(_classify_normalize "$file")"
  if _classify_match "$text" "$_CLASSIFY_LIMIT_RE"; then
    printf 'limit\n'
  elif _classify_match "$text" "$_CLASSIFY_LOCK_HEAD_RE" && _classify_match "$text" "$_CLASSIFY_LOCK_PROOF_RE"; then
    printf 'lock\n'
  elif _classify_match "$text" "$_CLASSIFY_AUTH_RE"; then
    printf 'auth\n'
  elif _classify_match "$text" "$_CLASSIFY_CAPACITY_RE"; then
    printf 'capacity\n'
  elif _classify_match "$text" "$_CLASSIFY_THROTTLE_RE"; then
    printf 'throttle\n'
  else
    printf 'other\n'
  fi
}

lock_id_from_log() {
  local esc=$'\033'
  sed -e "s/${esc}\[[0-9;]*[A-Za-z]//g" -e 's/│/ /g' "$1" 2>/dev/null |
    grep -A8 -i 'Lock Info:' |
    sed -nE 's/^[[:space:]]*ID:[[:space:]]+([0-9A-Za-z-]+)[[:space:]]*$/\1/p' |
    head -n1
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -uo pipefail
  classify_log "${1:-}"
fi
