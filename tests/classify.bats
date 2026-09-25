#!/usr/bin/env bats
# shellcheck shell=bats

bats_require_minimum_version 1.5.0

load helpers

setup() {
  # shellcheck source=../modules/oracle-a1/lib/classify.sh
  source "$CLASSIFY_SH"
}

expected_category() {
  case "$1" in
    capacity.log | workrequest-capacity.log | noisy-capacity.log | colour-capacity.log) printf capacity ;;
    limit.log | limit-regional.log | wrapped-limit.log | limit-and-capacity.log) printf limit ;;
    throttle.log | throttle-tenant.log | cli-throttle.log | cli-instances-throttle.log) printf throttle ;;
    auth.log | notfound.log | lock-put-denied.log | cli-auth.log | backend-auth.log) printf auth ;;
    cli-capacity-notauthorized.log | cli-instances-notauthorized.log) printf auth ;;
    lock.log) printf lock ;;
    other.log | validation-error.log | cli-capacity-error.log | workrequest-empty.log) printf other ;;
    *) return 1 ;;
  esac
}

scratch() {
  local file="$BATS_TEST_TMPDIR/$1"
  shift
  printf '%s\n' "$@" >"$file"
  printf '%s' "$file"
}

combined() {
  local file="$BATS_TEST_TMPDIR/combined-$1-$2"
  cat "$FIXTURES/$1" "$FIXTURES/$2" >"$file"
  printf '%s' "$file"
}

@test "every fixture log maps to its expected category" {
  local file name want got failures=()
  for file in "$FIXTURES"/*.log; do
    name="$(basename "$file")"
    want="$(expected_category "$name")" || {
      failures+=("$name has no expected category in classify.bats")
      continue
    }
    got="$(classify_log "$file")"
    [[ "$got" == "$want" ]] || failures+=("$name: want $want, got $got")
  done
  if ((${#failures[@]} > 0)); then
    printf '%s\n' "${failures[@]}" >&2
    return 1
  fi
}

@test "the required fixture set exists" {
  local name
  for name in capacity limit limit-regional throttle throttle-tenant auth notfound lock lock-put-denied \
    other validation-error workrequest-capacity noisy-capacity colour-capacity wrapped-limit \
    limit-and-capacity cli-auth cli-throttle backend-auth; do
    [[ -s "$FIXTURES/$name.log" ]] || fail_with "missing fixture $name.log"
  done
}

@test "provider fixtures follow the provider's service-error template" {
  local name
  for name in capacity limit limit-regional throttle throttle-tenant auth notfound other; do
    grep -qE '^Error: [0-9]{3}-[A-Za-z]+, ' "$FIXTURES/$name.log" || fail_with "$name.log: no 'Error: NNN-Code, ' line"
    grep -q '^Suggestion: ' "$FIXTURES/$name.log" || fail_with "$name.log: no Suggestion line"
    grep -q '^Provider version: 9.3.0, released on 2026-09-22.  $' "$FIXTURES/$name.log" || fail_with "$name.log: no version line"
    grep -q '^OPC request ID: .* $' "$FIXTURES/$name.log" || fail_with "$name.log: no OPC request ID line"
    grep -qE '^  with (oci_core_instance\.a1|data\.oci_core_images\.arm),$' "$FIXTURES/$name.log" || fail_with "$name.log: no source snippet"
  done
}

@test "CLI fixtures use the real OCI CLI error formats" {
  grep -q '^ServiceError:$' "$FIXTURES/cli-auth.log"
  grep -q '"status": 401,' "$FIXTURES/cli-auth.log"
  grep -q '^TransientServiceError:$' "$FIXTURES/cli-throttle.log"
  grep -q '"code": "TooManyRequests",' "$FIXTURES/cli-throttle.log"
  refute_contains "$(cat "$FIXTURES/cli-auth.log" "$FIXTURES/cli-throttle.log")" "401-"
  refute_contains "$(cat "$FIXTURES/cli-throttle.log")" "429-"
}

@test "lock.log is the real multi-line lock block with a 412 wrapped away from its label" {
  grep -q '^Error: Error acquiring the state lock$' "$FIXTURES/lock.log"
  grep -q 'Http Status Code:$' "$FIXTURES/lock.log"
  grep -q '^412\. Error Code: IfNoneMatchFailed\.' "$FIXTURES/lock.log"
  grep -q '^Lock Info:$' "$FIXTURES/lock.log"
  refute_contains "$(cat "$FIXTURES/lock.log")" "Precondition Failed"
  run awk 'length > 77 && !/^https?:/' "$FIXTURES/lock.log"
  [ -z "$output" ]
}

@test "limit beats capacity when both appear" {
  [ "$(classify_log "$FIXTURES/limit-and-capacity.log")" = limit ]
  [ "$(classify_log "$(combined capacity.log limit-regional.log)")" = limit ]
  [ "$(classify_log "$(combined workrequest-capacity.log limit.log)")" = limit ]
}

@test "limit beats lock and auth" {
  [ "$(classify_log "$(combined lock.log limit.log)")" = limit ]
  [ "$(classify_log "$(combined auth.log limit.log)")" = limit ]
}

@test "auth beats capacity and throttle" {
  [ "$(classify_log "$(combined capacity.log auth.log)")" = auth ]
  [ "$(classify_log "$(combined throttle.log notfound.log)")" = auth ]
  [ "$(classify_log "$(combined cli-throttle.log cli-auth.log)")" = auth ]
}

@test "lock beats auth when the contention proof is present" {
  [ "$(classify_log "$(combined auth.log lock.log)")" = lock ]
}

@test "capacity beats throttle" {
  [ "$(classify_log "$(combined throttle.log capacity.log)")" = capacity ]
}

@test "the lock heading alone is not proof of contention" {
  local f
  f="$(scratch heading-only.log '' 'Error: Error acquiring the state lock' '' 'Error message: context deadline exceeded')"
  [ "$(classify_log "$f")" = other ]
  [ "$(classify_log "$FIXTURES/lock-put-denied.log")" = auth ]
}

@test "the lock heading plus either proof token classifies as lock" {
  local f
  f="$(scratch proof-code.log 'Error: Error acquiring the state lock' 'Error message: Error returned by ObjectStorage Service. Http Status Code:' '412. Error Code: IfNoneMatchFailed.')"
  [ "$(classify_log "$f")" = lock ]
  f="$(scratch proof-info.log 'Error: Error acquiring the state lock' 'Error message: unexpected' 'Lock Info:' '  ID:        0e3f9a3c-1111-4222-8333-944455556666')"
  [ "$(classify_log "$f")" = lock ]
  f="$(scratch workspace.log 'Error: error loading state: failed to lock oci state: Error returned by ObjectStorage Service. Http Status Code: 412. Error Code: IfNoneMatchFailed.')"
  [ "$(classify_log "$f")" = lock ]
}

@test "proof tokens without the lock heading are not a lock" {
  local f
  f="$(scratch proof-only.log 'Error: something else' 'Error Code: IfNoneMatchFailed')"
  [ "$(classify_log "$f")" = other ]
}

@test "the noisy capacity log keeps its distractors and still classifies as capacity" {
  local text
  text="$(cat "$FIXTURES/noisy-capacity.log")"
  assert_contains "$text" "authentication"
  assert_contains "$text" "capacity_reservation_id"
  assert_contains "$text" "aaaaaaaa401"
  assert_contains "$text" "aaaaaaaa403"
  assert_contains "$text" "Acquiring state lock"
  assert_contains "$text" "rate limit and quota"
  [ "$(wc -l <"$FIXTURES/noisy-capacity.log")" -gt 200 ]
  [ "$(classify_log "$FIXTURES/noisy-capacity.log")" = capacity ]
}

@test "the noisy plan body alone does not over-match any category" {
  local f="$BATS_TEST_TMPDIR/noisy-body.log"
  sed '/^Error: 500-InternalError/,$d' "$FIXTURES/noisy-capacity.log" >"$f"
  refute_contains "$(cat "$f")" "Out of host capacity"
  [ "$(classify_log "$f")" = other ]
}

@test "bare 401, 403 and 'authentication' do not mean auth" {
  local f
  f="$(scratch bare.log 'Error: 400-InvalidParameter, port 401 is reserved for authentication' 'status 403 seen on ocid1.subnet.oc1..aaaa401-' 'authentication failed? no: 401 403')"
  [ "$(classify_log "$f")" = other ]
}

@test "every auth form matches: provider, Go SDK, CLI JSON, bucket and config errors" {
  local f
  f="$(scratch p401.log 'Error: 401-NotAuthenticated, x')"
  [ "$(classify_log "$f")" = auth ]
  f="$(scratch p403.log 'Error: 403-Forbidden, x')"
  [ "$(classify_log "$f")" = auth ]
  f="$(scratch sdk.log 'Error returned by ObjectStorage Service. Http Status Code:' '401. Error Code: Whatever.')"
  [ "$(classify_log "$f")" = auth ]
  f="$(scratch cli.log '{' '    "code": "Unknown",' '    "status": 403' '}')"
  [ "$(classify_log "$f")" = auth ]
  f="$(scratch key.log 'The provided key is not a private key, or the provided passphrase is incorrect.')"
  [ "$(classify_log "$f")" = auth ]
  f="$(scratch cfg.log 'Error: can not create client, bad configuration: did not find a proper configuration for region, nor for OCI_REGION env var')"
  [ "$(classify_log "$f")" = auth ]
  f="$(scratch profile.log 'Error: configuration file did not contain profile: DEFAULT')"
  [ "$(classify_log "$f")" = auth ]
}

@test "throttle matches the Go SDK form even when the status code is wrapped" {
  local f
  f="$(scratch sdk429.log 'Error message: Error returned by ObjectStorage Service. Http Status Code:' '429. Error Code: SlowDown.')"
  [ "$(classify_log "$f")" = throttle ]
  f="$(scratch cli429.log '{' '    "code": "Unknown",' '    "status": 429' '}')"
  [ "$(classify_log "$f")" = throttle ]
}

@test "InternalError and capacity only count as capacity when they are close together" {
  local f filler
  f="$(scratch near.log 'Error: 500-InternalError, not enough capacity in the fault domain')"
  [ "$(classify_log "$f")" = capacity ]
  filler="$(printf 'x%.0s' {1..400})"
  f="$(scratch far.log 'Error: 500-InternalError, Internal error occurred' "$filler" '  + capacity_reservation_id = (known after apply)')"
  [ "$(classify_log "$f")" = other ]
}

@test "ANSI colour and box prefixes do not hide a capacity error" {
  grep -q $'\033\\[' "$FIXTURES/colour-capacity.log"
  grep -q '│' "$FIXTURES/colour-capacity.log"
  [ "$(classify_log "$FIXTURES/colour-capacity.log")" = capacity ]
}

@test "a limit phrase split by the 77-column wrap is still a limit" {
  refute_contains "$(cat "$FIXTURES/wrapped-limit.log")" "service limits were exceeded"
  refute_contains "$(cat "$FIXTURES/wrapped-limit.log")" "LimitExceeded"
  [ "$(classify_log "$FIXTURES/wrapped-limit.log")" = limit ]
}

@test "the asynchronous work-request capacity failure is capacity" {
  grep -q 'work request did not succeed' "$FIXTURES/workrequest-capacity.log"
  [ "$(classify_log "$FIXTURES/workrequest-capacity.log")" = capacity ]
}

@test "a missing, unreadable or empty log classifies as other" {
  [ "$(classify_log "$BATS_TEST_TMPDIR/does-not-exist.log")" = other ]
  [ "$(classify_log "")" = other ]
  : >"$BATS_TEST_TMPDIR/empty.log"
  [ "$(classify_log "$BATS_TEST_TMPDIR/empty.log")" = other ]
}

@test "classify_log is pure: it prints one word and leaves the log untouched" {
  local before after
  before="$(cksum <"$FIXTURES/noisy-capacity.log")"
  run -0 --separate-stderr classify_log "$FIXTURES/noisy-capacity.log"
  after="$(cksum <"$FIXTURES/noisy-capacity.log")"
  [ "$output" = capacity ]
  [ "${#lines[@]}" -eq 1 ]
  [ -z "$stderr" ]
  [ "$before" = "$after" ]
}

@test "classify.sh can be executed directly" {
  run -0 bash "$CLASSIFY_SH" "$FIXTURES/limit.log"
  [ "$output" = limit ]
  run -0 bash "$CLASSIFY_SH"
  [ "$output" = other ]
}

@test "lock_id_from_log extracts the lock ID from lock.log" {
  [ "$(lock_id_from_log "$FIXTURES/lock.log")" = c0a8f6d2-5b7e-4f3a-9d21-7e4b8a6c1f90 ]
}

@test "lock_id_from_log survives colour and box prefixes" {
  local f="$BATS_TEST_TMPDIR/colour-lock.log"
  sed -e $'s/^/\033[31m│\033[0m /' "$FIXTURES/lock.log" >"$f"
  [ "$(lock_id_from_log "$f")" = c0a8f6d2-5b7e-4f3a-9d21-7e4b8a6c1f90 ]
}

@test "lock_id_from_log prints nothing without a Lock Info block" {
  [ -z "$(lock_id_from_log "$FIXTURES/lock-put-denied.log")" ]
  [ -z "$(lock_id_from_log "$FIXTURES/capacity.log")" ]
  run -0 lock_id_from_log "$BATS_TEST_TMPDIR/missing.log"
  [ -z "$output" ]
}

@test "user-chosen text such as 'not 401-protected' next to a capacity error stays capacity" {
  local f
  f="$(scratch named-401.log '  + description = "team 401-protected sandbox"' '  + display_name = "legacy-403-proxy"' "$(cat "$FIXTURES/capacity.log")")"
  [ "$(classify_log "$f")" = capacity ]
}

@test "the provider's NNN-Code, form still classifies 403 and 429" {
  local f
  f="$(scratch forbidden.log 'Error: 403-NotAllowed, The user is not allowed to perform this operation.')"
  [ "$(classify_log "$f")" = auth ]
  f="$(scratch throttled.log 'Error: 429-SomethingElse, Slow down.')"
  [ "$(classify_log "$f")" = throttle ]
}

@test "normalisation matters: a box-prefixed, colour, wrapped backend 403 is auth" {
  local f esc=$'\033'
  f="$(scratch colour-wrapped-403.log \
    "${esc}[31m│${esc}[0m ${esc}[0m${esc}[1m${esc}[31mError: ${esc}[0m${esc}[0m${esc}[1mError refreshing state${esc}[0m" \
    "${esc}[31m│${esc}[0m" \
    "${esc}[31m│${esc}[0m ${esc}[0mError returned by ObjectStorage Service. Http Status Code:" \
    "${esc}[31m│${esc}[0m ${esc}[0m403. Error Code: Forbidden. Opc request id: syd-1:abc")"
  [ "$(classify_log "$f")" = auth ]
}

@test "matching is case-insensitive" {
  local f
  f="$(scratch shouting.log 'Error: 500-InternalError, OUT OF HOST CAPACITY.')"
  [ "$(classify_log "$f")" = capacity ]
}
