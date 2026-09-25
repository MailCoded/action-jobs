#!/usr/bin/env bats
# shellcheck shell=bats

bats_require_minimum_version 1.5.0

load helpers

setup() {
  unset GITHUB_ACTIONS
  reset_outputs
}

in_common() {
  run --separate-stderr bash -c 'set -uo pipefail; source "$1"; shift; "$@"' _ "$COMMON_SH" "$@"
}

common_script() {
  run --separate-stderr bash -c 'set -uo pipefail; source "$1"; '"$1" _ "$COMMON_SH"
}

file_lines() {
  mapfile -t FILE_LINES <"$1"
}

@test "exit-code constants are 0/1/2/3 and read-only" {
  in_common declare -p EXIT_DONE EXIT_FATAL EXIT_RETRY EXIT_SKIPPED
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = 'declare -r EXIT_DONE="0"' ]
  [ "${lines[1]}" = 'declare -r EXIT_FATAL="1"' ]
  [ "${lines[2]}" = 'declare -r EXIT_RETRY="2"' ]
  [ "${lines[3]}" = 'declare -r EXIT_SKIPPED="3"' ]
}

@test "sourcing common.sh twice is harmless" {
  run --separate-stderr bash -c 'set -uo pipefail; source "$1"; source "$1"; printf ok' _ "$COMMON_SH"
  [ "$status" -eq 0 ]
  [ "$output" = ok ]
  [ -z "$stderr" ]
}

@test "status_exit_code maps every status" {
  local s want
  for s in "done:0" fatal:1 retry:2 skipped:3; do
    want="${s#*:}"
    run bash -c 'source "$1"; status_exit_code "$2"' _ "$COMMON_SH" "${s%%:*}"
    [ "$status" -eq 0 ]
    [ "$output" = "$want" ]
  done
  run bash -c 'source "$1"; status_exit_code bogus' _ "$COMMON_SH"
  [ "$status" -eq 1 ]
}

@test "finish done exits 0 and emits status, reason and message" {
  in_common finish "done" instance_created "All good"
  [ "$status" -eq 0 ]
  [ "$(gh_output status)" = "done" ]
  [ "$(gh_output reason)" = instance_created ]
  [ "$(gh_output message)" = "All good" ]
  gh_output_wellformed
}

@test "finish fatal, retry and skipped exit 1, 2 and 3" {
  in_common finish fatal auth "bad key"
  [ "$status" -eq 1 ]
  [ "$(gh_output status)" = fatal ]
  reset_outputs
  in_common finish retry no_capacity "later"
  [ "$status" -eq 2 ]
  [ "$(gh_output status)" = retry ]
  reset_outputs
  in_common finish skipped disabled "nothing to do"
  [ "$status" -eq 3 ]
  [ "$(gh_output status)" = skipped ]
}

@test "finish with an unknown status exits 1 and reports fatal" {
  in_common finish exploded weird "huh"
  [ "$status" -eq 1 ]
  [ "$(gh_output status)" = fatal ]
  [ "$(gh_output reason)" = weird ]
  assert_contains "$stderr" "unknown status 'exploded'"
}

@test "finish logs the outcome to stderr, not stdout" {
  in_common finish retry throttled "slow down"
  [ -z "$output" ]
  assert_contains "$stderr" "retry (throttled): slow down"
}

@test "finish annotates in Actions: error for fatal, warning for retry, notice otherwise" {
  export GITHUB_ACTIONS=true
  in_common finish fatal error "broken"
  [ "$output" = "::error::broken" ]
  in_common finish retry no_capacity "later"
  [ "$output" = "::warning::later" ]
  in_common finish "done" instance_present "fine"
  [ "$output" = "::notice::fine" ]
}

@test "emit writes a multi-line value in the heredoc delimiter format" {
  local value=$'line one\nline two\n\nline four'
  in_common emit message "$value"
  [ "$status" -eq 0 ]
  file_lines "$GITHUB_OUTPUT"
  [ "${#FILE_LINES[@]}" -eq 6 ]
  [[ "${FILE_LINES[0]}" =~ ^message\<\<ghadelimiter_[0-9a-f]+$ ]]
  [ "${FILE_LINES[1]}" = "line one" ]
  [ "${FILE_LINES[2]}" = "line two" ]
  [ "${FILE_LINES[3]}" = "" ]
  [ "${FILE_LINES[4]}" = "line four" ]
  [ "${FILE_LINES[5]}" = "${FILE_LINES[0]#message<<}" ]
  [ "$(gh_output message)" = "$value" ]
  gh_output_wellformed
}

@test "emit uses a fresh delimiter per call and handles empty values" {
  common_script 'emit a one; emit b; emit c ""'
  [ "$status" -eq 0 ]
  [ "$(gh_output a)" = one ]
  [ "$(gh_output b)" = "" ]
  [ "$(gh_output c)" = "" ]
  [ "$(grep -c '<<ghadelimiter_' "$GITHUB_OUTPUT")" -eq 3 ]
  [ "$(grep -o '<<ghadelimiter_[0-9a-f]*' "$GITHUB_OUTPUT" | sort -u | wc -l)" -eq 3 ]
}

@test "emit rejects an invalid output name without writing anything" {
  in_common emit "bad name" value
  [ "$status" -eq 1 ]
  [ ! -s "$GITHUB_OUTPUT" ]
  assert_contains "$stderr" "invalid output name"
}

@test "GITHUB_OUTPUT unset falls back to /dev/null without errors" {
  unset GITHUB_OUTPUT
  in_common emit key value
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
  in_common finish retry no_capacity "later"
  [ "$status" -eq 2 ]
  refute_contains "$stderr" "No such file"
}

@test "require_env returns 0 and prints nothing when everything is set" {
  export ALPHA_SETTING=a BETA_SETTING=b
  in_common require_env ALPHA_SETTING BETA_SETTING
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "require_env lists missing and empty names only, never values" {
  export PRESENT_SECRET="s3cr3t-value-never-printed"
  export EMPTY_SECRET=""
  unset ABSENT_SECRET
  in_common require_env PRESENT_SECRET ABSENT_SECRET EMPTY_SECRET
  [ "$status" -eq 1 ]
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[0]}" = ABSENT_SECRET ]
  [ "${lines[1]}" = EMPTY_SECRET ]
  refute_contains "$output$stderr" "s3cr3t-value-never-printed"
  refute_contains "$output" PRESENT_SECRET
}

@test "mask is a no-op outside GitHub Actions" {
  unset GITHUB_ACTIONS
  in_common mask $'secret-one\nsecret-two'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  export GITHUB_ACTIONS=false
  in_common mask "secret-one"
  [ -z "$output" ]
}

@test "mask emits one add-mask command per non-empty line inside Actions" {
  export GITHUB_ACTIONS=true
  in_common mask $'first-line\n   \n\nsecond-line\n  indented-line'
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 3 ]
  [ "${lines[0]}" = "::add-mask::first-line" ]
  [ "${lines[1]}" = "::add-mask::second-line" ]
  [ "${lines[2]}" = "::add-mask::  indented-line" ]
}

@test "mask handles a value without a trailing newline and an empty value" {
  export GITHUB_ACTIONS=true
  in_common mask "only-line"
  [ "$output" = "::add-mask::only-line" ]
  in_common mask ""
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "summary_line appends to GITHUB_STEP_SUMMARY" {
  common_script 'summary_line "## Title"; summary_line "second"'
  [ -z "$output" ]
  file_lines "$GITHUB_STEP_SUMMARY"
  [ "${#FILE_LINES[@]}" -eq 2 ]
  [ "${FILE_LINES[0]}" = "## Title" ]
  [ "${FILE_LINES[1]}" = "second" ]
}

@test "summary_line writes to stdout when GITHUB_STEP_SUMMARY is unset" {
  unset GITHUB_STEP_SUMMARY
  in_common summary_line "## Local run"
  [ "$status" -eq 0 ]
  [ "$output" = "## Local run" ]
}

@test "summary_table renders a header, separator and rows with escaped cells" {
  in_common summary_table 2 "Key" "Value" "pipe" "a|b" "newline" $'x\ny'
  [ "$status" -eq 0 ]
  file_lines "$GITHUB_STEP_SUMMARY"
  [ "${#FILE_LINES[@]}" -eq 4 ]
  [ "${FILE_LINES[0]}" = "| Key | Value |" ]
  [ "${FILE_LINES[1]}" = "|---|---|" ]
  [ "${FILE_LINES[2]}" = '| pipe | a\|b |' ]
  [ "${FILE_LINES[3]}" = "| newline | x y |" ]
}

@test "summary_table prints a trailing partial row and falls back to stdout" {
  unset GITHUB_STEP_SUMMARY
  in_common summary_table 3 A B C 1 2 3 4
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "| A | B | C |" ]
  [ "${lines[1]}" = "|---|---|---|" ]
  [ "${lines[2]}" = "| 1 | 2 | 3 |" ]
  [ "${lines[3]}" = "| 4 |" ]
}

@test "summary_table rejects a bad column count" {
  in_common summary_table 0 A
  [ "$status" -eq 1 ]
  in_common summary_table 3 A B
  [ "$status" -eq 1 ]
  in_common summary_table x A
  [ "$status" -eq 1 ]
  [ ! -s "$GITHUB_STEP_SUMMARY" ]
}

@test "summary_details wraps a log tail in a details block without ANSI or fences" {
  local log="$BATS_TEST_TMPDIR/tail.log"
  printf 'line %s\n' 1 2 3 4 5 >"$log"
  printf '\033[31mred\033[0m text\n```\n' >>"$log"
  in_common summary_details "Log | tail" "$log" 3
  [ "$status" -eq 0 ]
  file_lines "$GITHUB_STEP_SUMMARY"
  [ "${#FILE_LINES[@]}" -eq 9 ]
  [ "${FILE_LINES[0]}" = '<details><summary>Log \| tail</summary>' ]
  [ "${FILE_LINES[1]}" = "" ]
  [ "${FILE_LINES[2]}" = '```text' ]
  [ "${FILE_LINES[3]}" = "line 5" ]
  [ "${FILE_LINES[4]}" = "red text" ]
  [ "${FILE_LINES[5]}" = '` ` `' ]
  [ "${FILE_LINES[6]}" = '```' ]
  [ "${FILE_LINES[7]}" = "" ]
  [ "${FILE_LINES[8]}" = "</details>" ]
  refute_contains "$(summary_text)" $'\033'
  refute_contains "$(summary_text)" "line 4"
}

@test "summary_details writes nothing for a missing or empty file" {
  in_common summary_details "Nothing" "$BATS_TEST_TMPDIR/absent.log"
  [ "$status" -eq 0 ]
  : >"$BATS_TEST_TMPDIR/empty.log"
  in_common summary_details "Nothing" "$BATS_TEST_TMPDIR/empty.log"
  [ "$status" -eq 0 ]
  [ ! -s "$GITHUB_STEP_SUMMARY" ]
}

@test "summary_details goes to stdout when GITHUB_STEP_SUMMARY is unset" {
  unset GITHUB_STEP_SUMMARY
  printf 'hello\n' >"$BATS_TEST_TMPDIR/one.log"
  in_common summary_details "One" "$BATS_TEST_TMPDIR/one.log"
  assert_contains "$output" "<details><summary>One</summary>"
  assert_contains "$output" "hello"
}

@test "log writes a UTC timestamped line to stderr" {
  in_common log "hello world"
  [ -z "$output" ]
  [[ "$stderr" =~ ^\[[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\]\ hello\ world$ ]]
}

@test "warn and annotate only emit workflow commands inside Actions, escaping % CR LF" {
  in_common warn "careful"
  [ -z "$output" ]
  assert_contains "$stderr" "WARNING: careful"
  export GITHUB_ACTIONS=true
  in_common annotate error $'50% done\r\nnext'
  [ "$output" = "::error::50%25 done%0D%0Anext" ]
}
