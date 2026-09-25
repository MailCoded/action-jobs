# Modules

A module is one job the hub runs on a schedule: `oracle-a1` today, monitors or notifiers later.
Each module has its own workflow file, so it has its own cron, enable switch, logs and manual
trigger. Shared logic lives in `lib/common.sh` and the composite actions under `.github/actions/`,
never in a dispatcher.

## The contract

| Rule | Detail |
|---|---|
| Entrypoint | `modules/<name>/run.sh`: no arguments, configured only through environment variables, makes no assumption about the working directory. |
| Exit code | `0` done, `1` fatal, `2` retry, `3` skipped (table below). Nothing else. |
| Step outputs | Always `status`, `reason`, `message`, written by `finish`. Module-specific keys via `emit KEY VALUE` (oracle-a1 adds `public_ip`, `instance_id`, ...). |
| Job summary | The module writes its own Markdown to `$GITHUB_STEP_SUMMARY` (`summary_line`, `summary_table`, `summary_details`). Every status gets a useful summary; a fatal one says what to fix. |
| Runs locally | With `GITHUB_OUTPUT` unset, outputs go to `/dev/null`; with `GITHUB_STEP_SUMMARY` unset, the summary goes to stdout. Logs go to stderr. |
| Enable switch | Job-level `if: vars.<NAME>_ENABLED == 'true'`. Off by default, so a fresh fork does not fail on every tick. |
| Secrets | Report missing settings by **name** only (`require_env`); never print a value; `mask` any derived sensitive value. |
| Naming | Shared provider credentials use the provider prefix (`OCI_*`), module settings the module prefix (`ORACLE_A1_*`), hub-wide settings none (`APPRISE_URLS`). |
| Bounded | No unbounded loops; stop starting new work well before `timeout-minutes`. |
| Notify | On `done` and `fatal`, and when an earlier step fails. Never on `retry`. |

| Code | Status | Workflow result |
|---|---|---|
| 0 | `done` | green; the workflow may run post-success steps (oracle-a1 disables its own schedule) |
| 1 | `fatal` | red; needs a human |
| 2 | `retry` | green with a warning annotation; the next scheduled run tries again |
| 3 | `skipped` | green, neutral: nothing to do or not applicable |

### `lib/common.sh`

| Function | Purpose |
|---|---|
| `EXIT_DONE` `EXIT_FATAL` `EXIT_RETRY` `EXIT_SKIPPED` | The exit codes above. |
| `log MSG` / `warn MSG` | UTC-timestamped line on stderr; `warn` also adds a `::warning::` annotation in Actions. |
| `require_env NAME...` | Prints the names that are unset or empty and returns 1; prints nothing and returns 0 if all are set. |
| `mask VALUE` | `::add-mask::` for each non-blank line of VALUE (Actions only). |
| `emit KEY VALUE` | Writes a step output (multi-line safe). |
| `summary_line TEXT` / `summary_table NCOLS HEADER... CELL...` / `summary_details TITLE FILE [MAX_LINES]` | Job summary helpers; `summary_details` puts a log tail in a collapsed block. |
| `finish STATUS REASON MESSAGE` | Emits `status`/`reason`/`message`, annotates, logs and exits with the matching code. Every path ends here. |

## Adding module #2

1. **Code.** `mkdir modules/<name> && cp docs/module-template/run.sh modules/<name>/run.sh`.
   Rename `example`/`EXAMPLE_*`, list the required settings in `require_env`, and replace
   `check_target` with the real work. Keep one `conclude`/`finish` per outcome and pick
   `reason` values a human can act on. Run it locally with its settings exported:
   `modules/<name>/run.sh; echo $?`.
2. **Workflow.** `cp docs/module-template/workflow.yml.template .github/workflows/<name>.yml`.
   Rename `example` (workflow name, concurrency group, job id, `vars.<NAME>_ENABLED`, script path) and
   map secrets/variables into the run step's `env:`. Replace `<CHECKOUT_SHA>` with the SHA pinned in
   `oracle-a1.yml`, so every workflow uses the same version and Dependabot bumps them together.
   Pick a modest cron that avoids minute 0.
3. **Extras, only if needed.** Copy them from `oracle-a1.yml`: `hashicorp/setup-terraform` (same SHA,
   `terraform_version` and `terraform_wrapper: false`), `./.github/actions/setup-oci` for OCI
   credentials, or a post-success step (oracle-a1's `gh workflow disable` needs `actions: write`
   in `permissions`).
4. **Tests.** Add shims and a `tests/<name>.bats` that drive every status. Check that `ci.yml`'s
   ShellCheck and bats steps pick up the new files.
5. **Docs.** Add `modules/<name>/README.md` (settings, every reason with its fix, outputs), and list the
   module and its secrets/variables in the hub `README.md`.
6. **Enable.** Add the secrets and variables, set `<NAME>_ENABLED=true`, and run the workflow once by hand.
