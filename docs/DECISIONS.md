# Decisions and verification record

This file records what was checked against current docs, release pages and source code before
any code was written (SPEC §12), and every place where the implementation deliberately differs
from `SPEC.md`. Verification date: **2026-09-25**. Sources were the official docs, the release
pages, and the source trees at the pinned tags. Several behaviours were also reproduced locally
with the real Terraform 1.16.4 and OCI CLI 3.94.0 binaries, run against mock endpoints.

---

## 1. Pinned versions

| Component | Pin | Released | Where it is pinned | Updated by |
|---|---|---|---|---|
| Terraform CLI | **1.16.4** (latest 1.16.x; 1.17 is still beta) | 2026-09-23 | `oracle-a1.yml`, `ci.yml` | manual |
| Terraform `required_version` | `>= 1.12.0, < 2.0.0` | — | `versions.tf` | — |
| `oracle/oci` provider | constraint **`~> 9.3`**, lock file pins **9.3.0** | 2026-09-24 | `versions.tf`, `.terraform.lock.hcl` | Dependabot (terraform) |
| OCI CLI | **3.94.0** (`oci` SDK 2.187.0) | 2026-09-22 | `setup-oci/action.yml` | manual |
| Apprise | **1.13.1** | 2026-08-31 | `notify/action.yml` | manual |
| `actions/checkout` | **v7.0.1** = `3d3c42e5aac5ba805825da76410c181273ba90b1` | 2026-07-20 | workflows | Dependabot |
| `hashicorp/setup-terraform` | **v4.0.1** = `dfe3c3f87815947d99a8997f908cb6525fc44e9e` | 2026-05-12 | workflows | Dependabot |
| `actions/setup-python` | **v7.0.0** = `5fda3b95a4ea91299a34e894583c3862153e4b97` | 2026-07-20 | `setup-oci` (fallback only) | Dependabot |
| ShellCheck (CI) | **0.11.0**, `shellcheck-v0.11.0.linux.x86_64.tar.xz` sha256 `8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198` | 2025-08-04 | `ci.yml` | manual |
| actionlint (CI) | **1.7.12**, `actionlint_1.7.12_linux_amd64.tar.gz` sha256 `8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8` | 2026-03-30 | `ci.yml` | manual |
| bats-core (CI) | **v1.14.0** = commit `eb7f42f8d608ac693d7a4b67474f6714ea68cfc5` | 2026-07-21 | `ci.yml` | manual |
| Runner image | **`ubuntu-24.04`** (see D1) | image 20260907 | workflows | manual |

Tags were resolved to commits with `git ls-remote`. All three actions use lightweight tags, and
each moving major tag (`v7`, `v4`, `v7`) points at the same SHA. Checksums were recomputed
locally from the downloaded assets. ShellCheck publishes no checksum file, so its hash is
trust-on-first-use (GitHub's asset digest matches the local download).

"Manual" pins are not seen by Dependabot. Bump them by hand, together, a few times a year.

---

## 2. SPEC §12 checklist

| # | Item | Result |
|---|---|---|
| 1 | Latest Terraform 1.16.x | **1.16.4**. The native OCI backend exists since 1.12.0 (2025-05-14) and is GA, so `>= 1.12.0` is correct. |
| 2 | Latest `oracle/oci` | **9.3.0** (spec expected 9.1/9.2). Nothing between 9.0.0 and 9.3.0 changes `oci_core_instance`, `oci_core_images`, the network resources, retry handling or provider config: the instance resource file is byte-identical from 9.0.0 to 9.3.0. It still uses plugin protocol 5, so Terraform's minimum version does not move. Constraint `~> 9.3`. The lock file holds 3 `h1:` hashes (linux_amd64, linux_arm64, darwin_arm64) and 14 `zh:` hashes. |
| 3 | Current OCI CLI | **3.94.0**. `python_requires >= 3.6`, classifiers up to 3.13, and it installs from wheels on the runner's CPython 3.12.3. It does **not** declare 3.14 support, and PyYAML 6.0.2 (pinned `<=6.0.2`) has no cp314 wheels (see D1). |
| 4 | Action majors, SHAs, pipx | See §1. `setup-terraform` v4 moved to Node 24; its inputs (`terraform_version`, `terraform_wrapper`) are unchanged. `checkout` v7 still defaults `persist-credentials: true`, so we set it to `false`. **pipx 1.16.7 is preinstalled** on ubuntu-24.04: `PIPX_HOME=/opt/pipx`, `PIPX_BIN_DIR=/opt/pipx_bin` (on `PATH`), `/opt` is world-writable, so no sudo is needed. Terraform, bats and actionlint are **not** preinstalled. ShellCheck 0.9.0 is. |
| 5 | Native `backend "oci"` arguments, locking | The names `bucket`, `namespace`, `key`, `region`, `auth` and `config_file_profile` are all valid. Only `bucket` and `namespace` are required, and both work via `-backend-config` (but **not** via env vars). `auth` is matched case-insensitively: the code constant is `ApiKey`, the docs write `APIKey`, and both work (tested). With `config_file_profile` set, the backend reads only `$HOME/.oci/config` and requires a literal `[DEFAULT]` header. It ignores `OCI_CLI_CONFIG_FILE`. **Locking works**: a separate object `oracle-a1/terraform.tfstate.lock` is written with `If-None-Match: *`. Contention returns HTTP 412, error code `IfNoneMatchFailed`. With the default `-lock-timeout=0s` Terraform tries once and fails. The backend calls only ListObjects, HeadObject, GetObject, PutObject and DeleteObject, never GetNamespace or GetBucket. |
| 6 | `compute-capacity-report create` | Syntax exactly as in SPEC §3.5. CLI output keys are kebab-case: `data."shape-availabilities"[]."availability-status"`. The enum is exactly `AVAILABLE`, `OUT_OF_HOST_CAPACITY` and `HARDWARE_NOT_SUPPORTED`; anything else prints `UNKNOWN_ENUM_VALUE`. An empty result prints nothing and exits 0. `--compartment-id` "should always be the root compartment". IAM resource type is `compute-capacity-reports`, and only `manage` grants `COMPUTE_CAPACITY_REPORT_CREATE`. It is **not** part of instance-family. Without a fault domain, the docs say the report "includes information about all fault domains", so we read **all** entries, not just `[0]` (D9). |
| 7 | Exact error text | Terraform output from the provider (template in the provider's `errors.go`): `Error: 500-InternalError, Out of host capacity.` followed by `Suggestion: The service for this resource encountered an error. Please contact support for help with service: Core Instance` and `Documentation:`/`API Reference:`/`Request Target:`/`Provider version:`/`Service:`/`Operation Name:`/`OPC request ID:` lines. Limit: `Error: 400-LimitExceeded, The following service limits were exceeded: standard-a1-memory-count, standard-a1-core-count. Request a service limit increase from the service limits page in the console. `. Variants also include `-regional-` counts. 429 is `429-TooManyRequests, Too many requests for the user` (or `…for the tenant`). The **backend** and the **CLI** use different formats (`Http Status Code: 412. Error Code: IfNoneMatchFailed`, and JSON `"code": "NotAuthenticated", "status": 401`). The classifier handles all three (D5). |
| 8 | `retries_config_file` format, default 500 retry | The file is a JSON object keyed by status code (`"409"`, `"429"`, `"500"`, …). Each entry allows only `retry_max_duration` and `first_retry_sleep_duration`, both integer seconds; unknown keys fail provider configuration. `retry_max_duration` is a **total** budget per API call, and the last backoff can overshoot it by up to 5 % + 1 s. Defaults without a file: 409 → 2 min, **429 → 10 min**, 500 → 2 min, 4xx never. A **500 whose text contains "Out of host capacity" is never retried** by the provider, whatever the file says. The spec's premise that the provider retries capacity 500s "for several minutes" is therefore inaccurate. The cap is still worth having for 500s with other wording, and it matters most for 429 (D6). |
| 9 | Instance terminated out-of-band | **Dropped from state on refresh.** The provider voids a resource whose lifecycle state is `TERMINATED` (and on 404). A plan then shows `+ create` for `oci_core_instance.a1`, `resource_drift` shows `delete`, and `prior_state` has no `a1`. **`TERMINATING` is NOT dropped**: it stays in state, and because `state` is computed-only in our config the plan says **"No changes" (exit 0)**. That is why reconcile must read the refreshed `state` attribute itself (D2). A launch that is accepted and then fails during the create wait leaves a **tainted** `a1` in state, with state `TERMINATING`/`TERMINATED`. A create-wait **timeout** leaves a tainted instance that may be **alive** (D3). |
| 10 | `oci_core_images` returns Ubuntu 24.04 aarch64 | Very likely, but this can only be confirmed live. Standard Arm builds are named `Canonical-Ubuntu-24.04-aarch64-YYYY.MM.DD-N` (current: `…-2026.09.18-0`). `operating_system = "Canonical Ubuntu"`, `operating_system_version = "24.04"`. The provider's regex filter is **unanchored**, so `aarch64` also matches `Canonical-Ubuntu-24.04-Minimal-aarch64-…`. Only the exact `24.04` version filter keeps Minimal out, and Oracle says not to use Minimal on Arm. We therefore also drop Minimal/GPU names client-side (D8). `sort_by = "TIMECREATED"` is a valid value. |
| 11 | `gh workflow disable` with `GITHUB_TOKEN` + `actions: write` | **Works.** gh 2.100.0 makes a GET to `/actions/workflows/oracle-a1.yml` (needs Actions: read) and a PUT to `/actions/workflows/{id}/disable` (needs Actions: write). `write` includes `read`. Caveats: it also disables `workflow_dispatch` until `gh workflow enable`, and the file must keep the name `oracle-a1.yml` on the default branch. |
| 12 | Always Free A1 still 2 OCPU / 12 GB | **Yes.** The official Always Free page (last modified 2026-06-12) says: "the first 1,500 OCPU hours and 9,000 GB hours per month … equivalent to 2 OCPUs and 12 GB of memory" (was 3,000/18,000). A 2/12 instance running 24/7 in a 31-day month uses 1,488 OCPU-h and 8,928 GB-h, so it stays under. **Dates:** no Oracle page gives 2026-06-15 or 2026-08-18. The doc changed around **2026-06-12**. The 2026-08-18 enforcement date comes only from users quoting an Oracle email ("Action Required: OCI Always Free Update", received 2026-08-05); those users report over-limit instances were disabled or terminated. The README words this accordingly. |
| 13 | IAM statement for listing ADs | **The SPEC statement is invalid.** There is no `availability-domains` resource type. ListAvailabilityDomains requires `COMPARTMENT_INSPECT` → `inspect compartments in tenancy` (D7). |

Other confirmed facts: ap-sydney-1 has 1 AD with 3 fault domains. The idle-reclamation rule is
7 days with CPU p95, network and memory (A1 only) all below 20 %. Always Free block storage is
200 GB total, and the boot volume is 50 GB by default and at minimum. Default users are `ubuntu`
(Ubuntu images) and `opc` (Oracle Linux). Oracle platform images ship iptables rules that allow
only SSH; edit `/etc/iptables/rules.v4`, and never use `ufw`. Oracle's own guidance for "Out of
host capacity" is to try again later, try another AD, or omit the fault domain.

---

## 3. Deviations from SPEC.md

Each deviation follows reality or makes a safety rule from the spec stricter. None changes the
exit-code contract (§4.2), adds a runtime dependency, or can create more than one instance.

**D1: `runs-on: ubuntu-24.04` instead of `ubuntu-latest`.** GitHub is moving `ubuntu-latest` to
Ubuntu 26.04 between **2026-10-19 and 2026-11-19** (runner-images #14748). 26.04 ships Python 3.14,
which OCI CLI 3.94.0 does not declare support for, and its PyYAML pin has no 3.14 wheels.
ShellCheck would also jump from 0.9.0 to 0.11.0. Revisit once the OCI CLI supports 3.14.

**D2: reconcile reads the refreshed instance state from the saved plan.** SPEC §3.3 relies on
`plan -detailed-exitcode`. After a refresh, `run.sh` inspects `terraform show -json tfplan`
(`prior_state` is the refreshed state) and decides as follows:

| Refreshed `oci_core_instance.a1` | Action |
|---|---|
| absent (terminated out-of-band, 404) | go to the create path (orphan guard first). The reconcile plan's `+ create` is **never** applied as-is, because it would bypass the AD/FD loop, capacity report and orphan guard. |
| `state = TERMINATED` (only reachable without a refresh) | `terraform state rm`, then the create path |
| `state = TERMINATING` | **RETRY_LATER, reason `terminating`**. The next tick sees it dropped. Creating right away would probably hit `LimitExceeded` (FATAL), because the dying instance still holds the allowance. |
| tainted and alive (any other state) | see D3 |
| alive, not tainted | exit 0 ⇒ DONE; exit 2 ⇒ refuse if any `resource_changes` action on `a1` is `delete`, otherwise apply the saved plan |

Only `resource_changes` is checked for `delete`. `resource_drift` always shows `delete` after an
out-of-band termination, and counting it would turn every such case into a false
`refuse_destructive`. A new retry reason is not an exit-code change.

**D3: a tainted instance is only treated as absent when OCI confirms it is dead.** SPEC §3.3.4 says
tainted ⇒ create path. But a create whose wait for RUNNING timed out leaves a tainted instance that
can later become RUNNING, and the create path would then plan `-/+` and **destroy a live
instance**. That contradicts the spec's own top rule. So a tainted instance that is `TERMINATED`,
`TERMINATING` or gone follows D2. A tainted instance in any other state ⇒ **FATAL
`refuse_destructive`** with `terraform untaint oci_core_instance.a1` guidance. Similarly, if a
create attempt fails and leaves `a1` in state (an asynchronous launch failure), the run stops with
RETRY_LATER instead of attempting another create in the same run. The reason is `no_capacity` when
the log carries capacity wording, and `launch_failed` otherwise (for example an empty
work-request message). The next run's reconcile then cleans up a dead record, or refuses if the
instance is alive.

**D4: `terraform init` runs inside `run.sh`, not as a separate workflow step.** SPEC §3.1 puts
init/validate in the module flow, while the §7.1 skeleton has a separate step. Doing it inside
`run.sh` means the preflight reports a missing `OCI_STATE_BUCKET` or `OCI_STATE_NAMESPACE` by
**name** before init runs, init failures are classified and summarised through the module
contract, and local runs need no extra step. Init uses `-lockfile=readonly`, so a lock file that
has drifted from the committed one fails loudly. The backend region is always passed explicitly.

**D5: the error classifier reflects real output.**
- **Lock:** `412 Precondition Failed` never appears. The real output is `Error acquiring the state
  lock` + `Http Status Code: 412. Error Code: IfNoneMatchFailed` + a `Lock Info:` block. Worse,
  `Error acquiring the state lock` **also** heads non-contention failures of the lock PUT (for
  example a missing `manage objects` policy), and with lock checked before auth those would be
  misreported as `state_locked`. So `lock` requires the heading **and**
  (`IfNoneMatchFailed` or `Lock Info:`). The lock ID is extracted from the log for the
  force-unlock hint.
- **Auth:** beyond `401-`/`403-`/`NotAuthenticated`/`NotAuthorizedOrNotFound`, it also matches the
  Go SDK form (`Http Status Code: 401`), CLI JSON (`"status": 401`), `BucketNotFound`, and the
  OCI CLI/SDK key and config errors. It never matches a bare `401` or `authentication`.
- **Throttle** also matches `Http Status Code: 429` and the CLI JSON form. The CLI prints 429 and
  5xx as `TransientServiceError:`, not `ServiceError:`, so nothing is anchored on that prefix.
- **Normalisation:** Terraform emits ANSI colour and `│` box prefixes even when piped, and wraps
  detail lines at 78 columns. Every call passes `-no-color`, and the classifier additionally strips
  ANSI and box characters and joins lines before matching. The `InternalError`+`capacity` rule
  requires the two within a short window, so a log that merely contains both words far apart
  does not become a capacity miss.
- Order (limit → lock → auth → capacity → throttle → other) is unchanged.

**D6: `retries.json` budgets sit below the caps.** Because the last backoff can overshoot
`retry_max_duration` by up to 5 % + 1 s, the file uses 409/429 = **165 s** (worst case about
175 s ≤ 180 s) and 500 = **45 s** (about 50 s ≤ 60 s). The prototype's 180/60 simulate to
about 191/65 s. A 500 "Out of host capacity" is never retried regardless. CI validates the shape of
the file, because a typo in it breaks every provider configure.

**D7: IAM policy (`bootstrap/oracle/iam-policy.txt`).**
- `inspect availability-domains in tenancy` is **replaced** by `inspect compartments in tenancy`
  (ListAvailabilityDomains = `COMPARTMENT_INSPECT`).
- `read objectstorage-namespaces in tenancy` is **removed**. The backend never calls GetNamespace
  (namespace is a required argument), and the statement is a no-op anyway because GetNamespace needs
  no permission.
- `read buckets … where target.bucket.name = …` is **removed**. The backend never calls bucket APIs.
  `manage objects … where target.bucket.name = '<bucket>'` covers ListObjects, HeadObject,
  GetObject, PutObject (create + overwrite, lock) and DeleteObject (unlock). `use objects` would not
  be enough. Do not add a `target.object.name` condition, because it would decline ListObjects and
  break `terraform init`.
- The bucket statement gets its own `<bucket-location>` placeholder, because the bootstrap may put
  the bucket in a different compartment than the instance.
- The policy must be created in the root compartment (it contains `in tenancy` statements).
- `read instance-images in tenancy` is kept even though `inspect` would suffice for ListImages,
  because `read` also covers the `INSTANCE_IMAGE_READ` that LaunchInstance needs.
- Optional extras are documented but not required: `inspect volumes` (silences a harmless
  provider warning), and a tag-namespace statement if a launch ever fails on Oracle-Tags defaults.

**D8: image selection and the image check.**
- A Terraform `check` block only produces a **warning** (exit 0). With zero images the plan would
  instead fail with the unhelpful `Invalid index`. So the hard, helpful error is a **data-source
  `lifecycle { postcondition }`**, which is evaluated before anything indexes the list. The `check`
  block from the spec is kept too; it is harmless.
- Names containing `Minimal` or `GPU` are filtered out client-side (see §2 item 10).
- The `image_name` output comes from the image actually used by the instance: the instance's
  `source_details[0].source_id` is looked up in the image list, falling back to the OCID once
  that build rotates out of the list. `images[0]` changes every month and would report the wrong
  name after the next image release. A separate `oci_core_image` lookup was rejected because it
  adds an API call whose IAM requirements for Oracle-owned images are undocumented.

**D9: capacity report handling.** All `shape-availabilities` entries are read: any `AVAILABLE` ⇒
attempt; all `OUT_OF_HOST_CAPACITY`/`HARDWARE_NOT_SUPPORTED` ⇒ skip the AD; a CLI error, empty
output or `UNKNOWN_ENUM_VALUE` ⇒ inconclusive, attempt anyway. The CLI is run with
`--max-retries 2 --read-timeout 30`, because by default it retries a 429 for about 90 s. The report
always uses the tenancy (root) compartment.

**D10: composite actions keep their logic in `.sh` files next to `action.yml`.** actionlint cannot
lint composite actions. It only validates their metadata and inputs through the workflows that use
them, and it never runs ShellCheck on composite `run:` blocks. Each composite step is therefore a
one-line call to `$GITHUB_ACTION_PATH/<name>.sh`, and CI runs ShellCheck on those scripts. This
adds files to the §4.1 layout under `.github/actions/*/`.

**D11: CI tool installation.** `curl | bash` is banned (§9), so actionlint and ShellCheck are
downloaded from their GitHub releases and **sha256-verified**. bats is cloned at a tag and its
**commit SHA verified**. `terraform init -backend=false -lockfile=readonly` fails CI if the lock
file is missing a provider, conflicts with the version constraint, or does not match the downloaded
package. Missing per-platform `h1:` hashes only produce a warning in readonly mode (verified with
1.16.4), so CI additionally requires three `h1:` hashes (linux_amd64, linux_arm64, darwin_arm64).

**D12: Dependabot.** The `github-actions` ecosystem uses
`directories: ["/", "/.github/actions/*"]`, because `directory: "/"` does not scan composite
actions. The terraform ecosystem's updater bundles Terraform 1.15.x, so `required_version` must
keep admitting 1.15. Do not tighten it to `~> 1.16`.

**D13: preflight and extra reasons.** New `reason` values (the exit codes are unchanged):
`missing_config`, `missing_tool` and `invalid_config` (fatal), `terminating` and `launch_failed`
(retry). `done` distinguishes `instance_created`, `instance_present` (no resource changes, although
refreshed output values may be applied) and `instance_updated`. The full list is in
`modules/oracle-a1/README.md`. The module never returns exit 3 (`skipped`); the disabled case is
handled by the job-level `if:`, so no runner starts at all. `setup-oci` also validates its own inputs (it runs before
`run.sh`) and reports missing ones by their conventional secret names. It trims whitespace and CR
from secrets, lowercases the fingerprint (the SDK rejects upper case), and rejects OpenSSH and
encrypted keys before any `oci` call (an encrypted key would hang on a passphrase prompt).

**D14: single source of truth for sizing.** `run.sh` exports `TF_VAR_ocpus` and
`TF_VAR_memory_in_gbs` from `OCPUS`/`MEMORY_GB`, and `TF_VAR_tenancy_ocid`/`TF_VAR_region` from
`TENANCY_OCID`/`OCI_REGION`. The capacity report and Terraform can then never disagree. The
workflow no longer passes those `TF_VAR_*` values separately.

**D15: bounded runs.** `oci_core_instance` gets `timeouts { create = "10m" }`; the default is
45 min, which would outlive the 30-minute job. Note that this timeout bounds only the wait after
launch; the LaunchInstance call itself is bounded by `retries.json`. `run.sh` also stops starting
new attempts after `MAX_RUN_SECONDS` (default 600) and returns RETRY_LATER. An attempt started just
before that deadline can still take its lock wait (60 s), its LaunchInstance retry budget (about
175 s) and the full 10-minute create wait. The job timeout is therefore **30 minutes** instead of
the spec's 20 (setup of about 3 min + 600 s + about 865 s is about 27.5 min), so the runner is
never killed mid-operation, which would leave a stale lock or an unrecorded instance. Public-repo
minutes are free, and the extra time only matters in that pathological case. Every plan, apply and state command
uses `-lock-timeout=60s`, so a brief race with a manual run does not immediately become FATAL.

**D16: the orphan guard also recognises `TERMINATING`.** Untracked A1 instances in any state other
than `TERMINATED`/`TERMINATING` ⇒ FATAL `orphan`. Only `TERMINATING` ones ⇒ RETRY_LATER
`terminating` (consistent with D2). Limitation, kept as specified: ListInstances covers only the
target compartment. An A1 in another compartment surfaces as `LimitExceeded`, and that error's
guidance says so.

**D17: input hygiene.** `run.sh` trims surrounding whitespace and CR from every secret it
receives before use. A secret saved with a trailing newline would otherwise pass the
`ocid1.tenancy.` prefix check and then flow verbatim into `--compartment-id` and `TF_VAR_*`.
It also rejects an SSH "public key" that does not start with `ssh-ed25519 `, `ssh-rsa ` or
`ecdsa-sha2-`, without echoing it and before any OCI call. The Terraform variable
`ssh_public_key` is marked `sensitive`, so a private key pasted by mistake never appears in plan
output or in Terraform's "Invalid value for variable" message. This was verified with the real
provider: the key does not appear in the output. Region validation in `run.sh`, `setup-oci` and
`variables.tf` accepts multi-part names (`^[a-z]+(-[a-z]+)+-[0-9]+$`).

**D18: `setup-oci` step order.** Validating the inputs and writing the config comes first, then
pipx detection, the optional `setup-python` fallback, the CLI install, and finally the auth probe.
Missing or malformed secrets therefore fail in about a second, before the ~470 MB OCI CLI install.
The private key is passed only to the configure step. The probe explains throttling, network
errors, 404 (missing `inspect compartments`) and 401 differently, and always exits 1 (the job goes
red). Outside GitHub Actions it refuses to overwrite an existing `~/.oci/config`.

**D19: the bootstrap script takes `OCI_REGION`.** Buckets are regional. `create-state-bucket.sh`
passes `--region` (default `ap-sydney-1`) on every call, so an admin CLI profile with a different
default region cannot create the bucket in the wrong place. A wrongly placed bucket would later
surface as `BucketNotFound` (reported as `auth`). The script also prints the bucket's actual
compartment, which fills the `<bucket-location>` placeholder in the IAM policy. For that reason the
README quickstart creates the bucket before the policy, the reverse of SPEC §11.

**D20: success is announced with a GitHub issue.** GitHub's Actions notifications offer only
"failed workflows only" or every run. The first misses the success, and the second would mean a
notification every 15 minutes for the green `retry` runs. So after `done` (and the self-disable)
the workflow opens the issue "oracle-a1: the A1 instance is ready", assigned to and mentioning the
repository owner. Because the Actions bot assigns you, GitHub notifies you, including a push in
GitHub Mobile. This needs `issues: write` in `oracle-a1.yml`, and nowhere else. The issue has no IP,
only the run link. It is skipped when the workflow was already disabled (a queued run after a
success), and a failure to open it only warns (`continue-on-error`). If assignment fails, the issue
is opened unassigned and the @mention still notifies. Apprise remains the channel for non-GitHub
destinations.

**Verification beyond `validate`.** The Terraform module was also planned with the real
`oracle/oci` 9.3.0 provider against a local mock of the ListImages API
(`CLIENT_HOST_OVERRIDES`). The newest image in the mock was a Minimal build: it was skipped and the
standard `Canonical-Ubuntu-24.04-aarch64-*` build was chosen. The outputs evaluated, the plan JSON
has the shape `run.sh` parses, and with only a Minimal image available the data-source
postcondition failed with its helpful message, which the classifier routes to FATAL `error`.

---

## 4. Only verifiable on the first real run

1. Whether the image query returns `Canonical-Ubuntu-24.04-aarch64-*` (and never Minimal) in the
   tenancy. The job summary shows the selected image name.
2. Whether `inspect compartments in tenancy` is sufficient for ListAvailabilityDomains (the docs say
   yes). The `setup-oci` auth probe tests exactly this.
3. The real OCI response when the state lock is contended (`IfNoneMatchFailed` is documented only
   in third-party captures). The classifier also accepts `Lock Info:`.
4. Whether an A1 capacity miss arrives synchronously (`500-InternalError, Out of host capacity.`),
   which is expected, or as an asynchronous work-request failure. Both are handled.
5. Whether a capacity report without a fault domain returns one entry or one per FD. Both are handled.
6. Whether a skipped scheduled run (`ORACLE_A1_ENABLED` unset) shows as "Skipped" in the Actions UI.
   This has been observed, but it is not documented.
7. Upstream issue oracle/terraform-provider-oci#2630: tag-only updates to an instance can fail. Our
   tags never change after creation. If they ever do, the failure classifies as FATAL `error`, which
   is safe.
