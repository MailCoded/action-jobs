#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  NOTIFY="$REPO_ROOT/.github/actions/notify/notify.sh"

  export HOME="$BATS_TEST_TMPDIR/home"
  STUB_BIN="$BATS_TEST_TMPDIR/stubs"
  mkdir -p "$HOME" "$STUB_BIN"

  export GITHUB_ACTIONS=true
  unset GITHUB_SERVER_URL GITHUB_REPOSITORY GITHUB_RUN_ID GITHUB_WORKFLOW
  unset APPRISE_URLS NOTIFY_TITLE NOTIFY_BODY NOTIFY_STATUS APPRISE_VERSION
  unset FAKE_PIPX_LIST FAKE_PIPX_RC FAKE_APPRISE_RC

  export PIPX_CALLS="$BATS_TEST_TMPDIR/pipx.calls"
  export APPRISE_CALLS="$BATS_TEST_TMPDIR/apprise.calls"
  export APPRISE_ARGS="$BATS_TEST_TMPDIR/apprise.args"
  export APPRISE_ENV="$BATS_TEST_TMPDIR/apprise.env"
  export FAKE_PIPX_BIN="$BATS_TEST_TMPDIR/pipx-bin"

  write_pipx_stub
  PATH="$STUB_BIN:$(minimal_path)"
}

minimal_path() {
  local dir="$BATS_TEST_TMPDIR/sysbin" tool found
  mkdir -p "$dir"
  for tool in bash env cat grep sed awk tr tail head dirname basename date mkdir chmod rm od \
    sort mktemp readlink timeout stat wc cmp ls cp mv touch tee uname sleep kill cut find; do
    if found="$(command -v "$tool")"; then
      ln -sf "$found" "$dir/$tool"
    fi
  done
  printf '%s' "$dir"
}

# The apprise stub lands in PIPX_BIN_DIR, so a passing send also proves that dir is put on PATH.
write_apprise_stub() {
  local dir="$1"
  mkdir -p "$dir"
  cat >"$dir/apprise" <<'STUB'
#!/usr/bin/env bash
printf 'call\n' >>"$APPRISE_CALLS"
printf '%s\0' "$@" >"$APPRISE_ARGS"
printf '%s' "${APPRISE_URLS-<unset>}" >"$APPRISE_ENV"
printf 'apprise stub: sending\n'
exit "${FAKE_APPRISE_RC:-0}"
STUB
  chmod +x "$dir/apprise"
}

write_pipx_stub() {
  cat >"$STUB_BIN/pipx" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$PIPX_CALLS"
case "$1" in
  list) [[ -z "${FAKE_PIPX_LIST:-}" ]] || printf '%s\n' "$FAKE_PIPX_LIST" ;;
  environment) printf '%s\n' "$FAKE_PIPX_BIN" ;;
  install) exit "${FAKE_PIPX_RC:-0}" ;;
esac
exit 0
STUB
  chmod +x "$STUB_BIN/pipx"
  write_apprise_stub "$FAKE_PIPX_BIN"
}

apprise_args() {
  mapfile -d '' -t ARGS <"$APPRISE_ARGS"
}

arg_after() {
  local i
  apprise_args
  for ((i = 0; i < ${#ARGS[@]} - 1; i++)); do
    if [[ "${ARGS[i]}" == "$1" ]]; then
      printf '%s' "${ARGS[i + 1]}"
      return 0
    fi
  done
  return 1
}

apprise_call_count() {
  if [[ -e "$APPRISE_CALLS" ]]; then
    grep -c '^call$' "$APPRISE_CALLS"
  else
    printf '0'
  fi
}

@test "blank APPRISE_URLS sends nothing and installs nothing" {
  local value
  for value in "" "   " $' , ,\n\t,'; do
    export APPRISE_URLS="$value"
    run -0 "$NOTIFY"
    [[ "$output" == *"APPRISE_URLS is empty"* ]]
  done
  [[ ! -e "$PIPX_CALLS" ]]
  [[ "$(apprise_call_count)" == "0" ]]
}

@test "each URL is masked individually before anything else is printed" {
  export APPRISE_URLS=$'json://hooks.example/one, tgram://123456:ABCdef/789\nntfys://topic-x,,mailto://u:p%40ss@mail.example'
  export NOTIFY_STATUS="done" NOTIFY_TITLE="oracle-a1: done" NOTIFY_BODY="ok"
  run -0 "$NOTIFY"
  [[ "${lines[0]}" == "::add-mask::json://hooks.example/one" ]]
  [[ "${lines[1]}" == "::add-mask::tgram://123456:ABCdef/789" ]]
  [[ "${lines[2]}" == "::add-mask::ntfys://topic-x" ]]
  [[ "${lines[3]}" == "::add-mask::mailto://u:p%2540ss@mail.example" ]]
  [[ "$(grep -c '^::add-mask::' <<<"$output")" == "4" ]]
}

@test "outside GitHub Actions the URLs are not echoed" {
  unset GITHUB_ACTIONS
  export APPRISE_URLS="json://hooks.example/secret-token"
  run -0 "$NOTIFY"
  [[ "$output" != *"secret-token"* ]]
}

@test "apprise gets the URLs only through the environment, without verbosity and with the right type" {
  export APPRISE_URLS="json://hooks.example/one, ntfys://topic-x"
  export NOTIFY_STATUS="done" NOTIFY_TITLE="oracle-a1: done" NOTIFY_BODY="A1 instance is ready at 203.0.113.7"
  run -0 "$NOTIFY"
  [[ "$(apprise_call_count)" == "1" ]]
  [[ "$(cat "$APPRISE_ENV")" == "json://hooks.example/one, ntfys://topic-x" ]]
  [[ "$(arg_after -n)" == "success" ]]
  [[ "$(arg_after -t)" == "oracle-a1: done" ]]
  [[ "$(arg_after -b)" == "A1 instance is ready at 203.0.113.7" ]]

  apprise_args
  local i arg values=0
  for ((i = 0; i < ${#ARGS[@]}; i++)); do
    arg="${ARGS[i]}"
    if [[ "$arg" == "-n" || "$arg" == "-t" || "$arg" == "-b" ]]; then
      i=$((i + 1))
      values=$((values + 1))
      continue
    fi
    [[ "$arg" == -* ]]
    [[ "$arg" != *"://"* ]]
    [[ "$arg" != -v* && "$arg" != "-D" && "$arg" != "--debug" && "$arg" != "--verbose" ]]
  done
  [[ "$values" == "3" ]]
}

@test "status selects the apprise notification type" {
  export APPRISE_URLS="json://hooks.example/one" NOTIFY_TITLE="t" NOTIFY_BODY="b"
  local status expected
  for status in done:success fatal:failure failed:failure failure:failure retry:info :info; do
    expected="${status#*:}"
    export NOTIFY_STATUS="${status%%:*}"
    run -0 "$NOTIFY"
    [[ "$(arg_after -n)" == "$expected" ]]
  done
}

@test "the pinned apprise is installed with pipx, forced only over another version" {
  export APPRISE_URLS="json://hooks.example/one" NOTIFY_BODY="b"
  run -0 "$NOTIFY"
  grep -qx 'install apprise==1.13.1' "$PIPX_CALLS"

  rm -f "$PIPX_CALLS"
  export FAKE_PIPX_LIST="apprise 1.9.0"
  run -0 "$NOTIFY"
  grep -qx 'install --force apprise==1.13.1' "$PIPX_CALLS"

  rm -f "$PIPX_CALLS"
  export FAKE_PIPX_LIST="apprise 1.13.1"
  run -0 "$NOTIFY"
  run -1 grep -q '^install' "$PIPX_CALLS"
}

@test "an apprise failure is only a warning" {
  export APPRISE_URLS="json://hooks.example/one" NOTIFY_BODY="b" FAKE_APPRISE_RC=1
  run -0 "$NOTIFY"
  [[ "$output" == *"::warning::Notification failed (apprise exit 1)"* ]]
}

@test "an apprise timeout is only a warning" {
  export APPRISE_URLS="json://hooks.example/one" NOTIFY_BODY="b" FAKE_APPRISE_RC=124
  run -0 "$NOTIFY"
  [[ "$output" == *"::warning::Notification timed out"* ]]
}

@test "a failed apprise install is only a warning and nothing is sent" {
  export APPRISE_URLS="json://hooks.example/one" NOTIFY_BODY="b" FAKE_PIPX_RC=1
  run -0 "$NOTIFY"
  [[ "$output" == *"::warning::Could not install apprise 1.13.1"* ]]
  [[ "$(apprise_call_count)" == "0" ]]
}

@test "without pipx or python the notification is skipped with a warning" {
  rm -f "$STUB_BIN/pipx"
  export APPRISE_URLS="json://hooks.example/one" NOTIFY_BODY="b"
  run -0 "$NOTIFY"
  [[ "$output" == *"::warning::Could not install apprise"* ]]
  [[ "$(apprise_call_count)" == "0" ]]
}

@test "without pipx, apprise is installed with pip --user" {
  rm -f "$STUB_BIN/pipx"
  export PY_CALLS="$BATS_TEST_TMPDIR/python.calls" PY_USER_BASE="$BATS_TEST_TMPDIR/user-base"
  write_apprise_stub "$PY_USER_BASE/bin"
  cat >"$STUB_BIN/python3" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$PY_CALLS"
[[ "$1 $2" == "-m site" ]] && printf '%s\n' "$PY_USER_BASE"
exit 0
STUB
  chmod +x "$STUB_BIN/python3"
  export APPRISE_URLS="json://hooks.example/one" NOTIFY_BODY="b"
  run -0 "$NOTIFY"
  grep -q -- '-m pip install --user .*apprise==1.13.1' "$PY_CALLS"
  [[ "$(apprise_call_count)" == "1" ]]
}

@test "empty title and body get defaults that link to the run" {
  export APPRISE_URLS="json://hooks.example/one" NOTIFY_STATUS=failed
  export GITHUB_SERVER_URL="https://github.com" GITHUB_REPOSITORY="andrew/freebie-hub" GITHUB_RUN_ID="12345" GITHUB_WORKFLOW="oracle-a1"
  run -0 "$NOTIFY"
  [[ "$(arg_after -t)" == "oracle-a1: failed" ]]
  local body
  body="$(arg_after -b)"
  [[ "$body" == *"No details were reported"* ]]
  [[ "$body" == *"https://github.com/andrew/freebie-hub/actions/runs/12345"* ]]
}

@test "without run details the defaults are still non-empty" {
  export APPRISE_URLS="json://hooks.example/one"
  run -0 "$NOTIFY"
  [[ -n "$(arg_after -t)" ]]
  [[ -n "$(arg_after -b)" ]]
}

@test "a given body gets the run link appended once" {
  export APPRISE_URLS="json://hooks.example/one" NOTIFY_BODY="Invalid configuration"
  export GITHUB_SERVER_URL="https://github.com" GITHUB_REPOSITORY="andrew/freebie-hub" GITHUB_RUN_ID="42"
  run -0 "$NOTIFY"
  [[ "$(arg_after -b)" == $'Invalid configuration\n\nRun: https://github.com/andrew/freebie-hub/actions/runs/42' ]]

  export NOTIFY_BODY="See https://github.com/andrew/freebie-hub/actions/runs/42"
  run -0 "$NOTIFY"
  [[ "$(arg_after -b)" == "See https://github.com/andrew/freebie-hub/actions/runs/42" ]]
}

@test "title and body are passed verbatim and never evaluated" {
  local marker="$BATS_TEST_TMPDIR/pwned"
  export APPRISE_URLS="json://hooks.example/one"
  export NOTIFY_TITLE="t \$(touch $marker)"
  export NOTIFY_BODY="\`touch $marker\` \$(touch $marker) \"quoted\" 'single' %0A ::error::x"
  run -0 "$NOTIFY"
  [[ ! -e "$marker" ]]
  [[ "$(arg_after -t)" == "$NOTIFY_TITLE" ]]
  [[ "$(arg_after -b)" == "$NOTIFY_BODY" ]]
}
