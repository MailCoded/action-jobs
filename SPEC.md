# freebie-hub — Build Specification

**v1 scope:** one module, `oracle-a1` — get an Oracle Cloud Always Free `VM.Standard.A1.Flex` with **2 OCPU / 12 GB** in home region **`ap-sydney-1`**, driven by scheduled GitHub Actions + Terraform.
**Designed for:** additional modules later (monitors, notifiers, other freebies) without restructuring.
**Owner:** Andrew · **Implementer:** Claude Code · **Spec date:** 2026-09-25

---

## 0. Instructions for Claude Code

1. Build the repository described here. v1 ships exactly **one** module (`oracle-a1`) plus the minimal shared scaffolding that makes a second module cheap to add. Do not build future modules.
2. This spec reflects docs and releases as of September 2026. **Before writing code, work through §12 (Verification checklist)** against current official docs/release pages and pin exact versions. If reality contradicts the spec, follow reality, record the deviation in `docs/DECISIONS.md`, and tell me.
3. A prototype (`oracle-a1-provisioner.zip`) may be provided. Reuse what's useful; **where it differs from this spec, the spec wins.** Known differences are listed in §13.
4. You cannot reach my OCI tenancy. Everything must be testable offline with shims (§10). The first real run happens in my fork.
5. Ask me before: adding runtime dependencies beyond bash, jq, Terraform, OCI CLI, Python (for OCI CLI / Apprise) and bats; changing the exit-code contract (§4.2); or introducing anything that could create more than one A1 instance.

### Non-goals for v1

- No multiple Oracle accounts or anything that circumvents Free Tier rules.
- No Steam/Epic/other claimers, no generic matrix dispatcher, no VPS-side agent.
- No GitHub OIDC → OCI federation (API-key auth is fine for v1).
- No infinite loops inside a runner; no dummy-commit "keepalive" tricks.

---

## 1. Goal

A **public** GitHub repository. A scheduled workflow repeatedly and politely tries to create **one** A1 instance in my tenancy's home region until OCI has capacity. Terraform owns the instance; its state lives in OCI Object Storage so every ephemeral runner sees the same truth. Each run is bounded. On success the workflow reports the IP and **disables its own schedule**. Capacity misses are a normal "try later" outcome; every other failure stops loudly with a clear reason.

---

## 2. Fixed facts and constraints

| Topic | Fact / decision |
|---|---|
| Home region | `ap-sydney-1` (confirmed by owner). Always Free A1 can only be launched in the tenancy's home region; home region can't be changed. |
| ADs / FDs | Sydney has **1 availability domain** and 3 fault domains. Still discover ADs dynamically so the code works in any region. |
| Target shape | `VM.Standard.A1.Flex`, **2 OCPU / 12 GB**, Ubuntu 24.04 aarch64 (configurable). |
| Free allowance | Since 2026-06-15 Always Free A1 = 1,500 OCPU-h + 9,000 GB-h/month ≈ **2 OCPU / 12 GB total**; Oracle terminates over-allowance instances (enforced from 2026-08-18). 2/12 = the entire allowance, so **any other A1 in the tenancy ⇒ `LimitExceeded`**. |
| Storage | Boot volume default 50 GB; 200 GB total Always Free block storage. |
| Idle reclamation | Oracle may reclaim Always Free instances idle for 7 days (CPU p95, network and memory all < 20%). Out of scope for v1 — document in README only. |
| GitHub minutes | Public repo ⇒ standard runners are free. A private repo would exhaust 2,000 min/month in about a week at this cadence. |
| GitHub schedules | Best-effort, min 5 min interval, frequently delayed/dropped at the top of the hour. Public-repo schedules auto-disable after 60 days of no repo activity. |
| GitHub ToS | Actions shouldn't be used for activity unrelated to the repo's software. Mitigation: infra-as-code framing, modest cadence, self-disable on success. |

---

## 3. Required behaviour (oracle-a1 module)

### 3.1 Per-run flow

```
trigger (schedule | workflow_dispatch)
  └─ job skipped unless vars.ORACLE_A1_ENABLED == 'true'
       ├─ preflight: required secrets/vars present? ── no ─► FATAL (list missing NAMES, never values)
       ├─ write ~/.oci/config + PEM, validate PEM header ── bad ─► FATAL (auth)
       ├─ auth probe: list ADs ── fail ─► FATAL (auth)
       ├─ terraform init (remote backend) + validate ── fail ─► FATAL
       ├─ instance already in state? ── yes ─► RECONCILE (§3.3)
       ├─ orphan guard (§3.4) ── orphan found ─► FATAL (orphan)
       └─ for each AD:
            capacity report (if enabled) ── OUT_OF_HOST_CAPACITY / HARDWARE_NOT_SUPPORTED ─► next AD
            for each placement in [no fault domain] (+ FD-1..3 if try_fault_domains):
               terraform apply
                 ├─ ok ─────────► DONE (outputs, summary, notify, disable schedule)
                 ├─ capacity ───► sleep, next placement / AD
                 ├─ throttle ───► RETRY_LATER immediately (don't keep poking)
                 └─ limit | auth | lock | other ─► FATAL
       all exhausted ─► RETRY_LATER (reason no_capacity)
```

### 3.2 Error classification

Implement as a **pure function** in its own file (`modules/oracle-a1/lib/classify.sh`) that reads a log file and prints one category. Check in this order — order matters so a limit error can never be mistaken for a capacity miss:

| Order | Category | Match (case-insensitive; refine against real output) | Result |
|---|---|---|---|
| 1 | `limit` | `LimitExceeded`, `service limits? (was\|were) exceeded`, `QuotaExceeded`, `standard-a1-(core\|memory)(-regional)?-count` | FATAL, reason `limit_exceeded` |
| 2 | `lock` | `Error acquiring the state lock`, `412 Precondition Failed` on the state object | FATAL, reason `state_locked` (print `terraform force-unlock` guidance) |
| 3 | `auth` | `NotAuthenticated`, `401-`, `NotAuthorizedOrNotFound`, `403-`, invalid key/fingerprint messages | FATAL, reason `auth` |
| 4 | `capacity` | `Out of host capacity`, `Out of capacity for shape`, `OutOfCapacity`, `InternalError` together with `capacity` | continue loop |
| 5 | `throttle` | `TooManyRequests`, `429-` | RETRY_LATER, reason `throttled` |
| 6 | `other` | anything else | FATAL, reason `error` |

Keep the regexes tight: e.g. don't match a bare `401` or `authentication` anywhere in a long Terraform log. Fixture logs for tests are in §10.2.

### 3.3 Reconcile (instance already in state)

A scheduled run must **never** destroy or replace a live instance.

1. `terraform plan -detailed-exitcode -out=tfplan`.
2. If no changes ⇒ DONE.
3. If changes: inspect `terraform show -json tfplan`. If any action on `oci_core_instance.a1` includes `delete` (replace or destroy) ⇒ FATAL, reason `refuse_destructive`, print the planned actions. Otherwise apply the plan ⇒ DONE.
4. Special case: if the tracked instance is **tainted** or its `state` attribute is `TERMINATED`/`TERMINATING` (e.g. a failed launch, or I terminated it in the console), treat it as absent and go down the create path. Verify how the provider behaves when an instance is terminated out-of-band (it may already drop it from state on refresh) and handle both cases.

### 3.4 Orphan guard (nothing in state)

Before creating, list non-terminated `VM.Standard.A1.Flex` instances in the target compartment (OCI CLI). If any exist that aren't in state ⇒ FATAL, reason `orphan`, with `terraform import` instructions. This prevents confusing `LimitExceeded` loops after state loss.

### 3.5 Capacity report

Advisory gate before each apply (on by default):

```bash
oci compute compute-capacity-report create \
  --availability-domain "$AD" \
  --compartment-id "$TENANCY_OCID" \        # must be the root compartment
  --shape-availabilities '[{"instanceShape":"VM.Standard.A1.Flex","instanceShapeConfig":{"ocpus":2,"memoryInGBs":12}}]' \
  --query 'data."shape-availabilities"[0]."availability-status"' --raw-output
```

`AVAILABLE` ⇒ attempt apply. `OUT_OF_HOST_CAPACITY` / `HARDWARE_NOT_SUPPORTED` ⇒ skip AD. Anything else (error, empty) ⇒ log "inconclusive" and attempt anyway. The report is a snapshot and has been reported inaccurate, so the apply result is authoritative.

### 3.6 Pacing

Sleep 15–30 s between attempts within a run. Never retry the same placement twice in one run. Provider-level retries must stay short (§5.2) so one capacity miss doesn't hold the runner for minutes.

---

## 4. Repository architecture

### 4.1 Layout

```
freebie-hub/
├── .github/
│   ├── actions/
│   │   ├── setup-oci/action.yml      # install pinned OCI CLI, write ~/.oci/config + PEM, validate, auth probe
│   │   └── notify/action.yml         # Apprise fan-out; no-op if APPRISE_URLS empty
│   ├── workflows/
│   │   ├── oracle-a1.yml             # schedule + dispatch; the only module workflow in v1
│   │   └── ci.yml                    # lint + tests on push/PR (never touches OCI)
│   └── dependabot.yml                # github-actions + terraform ecosystems
├── lib/
│   └── common.sh                     # shared helpers (§4.3)
├── modules/
│   └── oracle-a1/
│       ├── README.md                 # module docs: secrets, vars, behaviour, troubleshooting
│       ├── run.sh                    # module entrypoint (contract §4.2)
│       ├── lib/classify.sh           # pure error classifier
│       ├── scripts/check-home-region.sh
│       └── terraform/
│           ├── versions.tf  providers.tf  backend.tf  retries.json
│           ├── variables.tf data.tf  network.tf  main.tf  outputs.tf
│           ├── terraform.tfvars.example
│           └── .terraform.lock.hcl   # committed, multi-platform hashes
├── bootstrap/
│   └── oracle/
│       ├── create-state-bucket.sh    # one-off, run locally with admin profile
│       └── iam-policy.txt            # policy statements (§11)
├── tests/
│   ├── shims/{oci,terraform}         # fake binaries driven by FAKE_SCENARIO
│   ├── fixtures/*.log                # real-looking OCI/Terraform error output
│   ├── classify.bats
│   └── oracle-a1.bats                # scenario tests (§10.3)
├── docs/
│   ├── MODULES.md                    # module contract + "adding a module" guide
│   ├── module-template/              # run.sh + workflow YAML templates (not live workflows)
│   └── DECISIONS.md                  # deviations from this spec, with reasons
├── README.md                         # hub overview + oracle-a1 quickstart
└── .gitignore
```

One workflow file per module, because each module needs its own cron, enable switch, logs and manual trigger. Shared logic goes into composite actions and `lib/common.sh`, not a dispatcher.

### 4.2 Module contract (document in `docs/MODULES.md`)

- Entrypoint `modules/<name>/run.sh`, no arguments, configured only via environment variables.
- **Exit codes (hub-wide):**

  | Code | Status | Workflow result |
  |---|---|---|
  | 0 | `done` | green; module may run post-success actions (oracle-a1: disable schedule) |
  | 1 | `fatal` | red; needs a human |
  | 2 | `retry` | green + warning; next schedule tick retries |
  | 3 | `skipped` | green, neutral (nothing to do / not applicable) |

- Writes to `$GITHUB_OUTPUT` via `lib/common.sh`: always `status`, `reason`, `message`; module-specific keys allowed (oracle-a1: `public_ip`, `instance_id`, `availability_domain`, `fault_domain`, `image_name`, `ocpus`, `memory_in_gbs`).
- Writes its own Markdown to `$GITHUB_STEP_SUMMARY` (keeps workflows thin and modules portable).
- Must run locally too: when `GITHUB_OUTPUT` / `GITHUB_STEP_SUMMARY` are unset, fall back to `/dev/null` / stdout.
- Enabled by repository variable `<MODULE>_ENABLED == 'true'` (default off, so a fresh fork doesn't fail every 15 minutes).
- Secret naming: shared provider credentials use a provider prefix (`OCI_*`, reusable by future OCI modules); module-specific settings use the module prefix (`ORACLE_A1_*`); hub-wide settings are unprefixed (`APPRISE_URLS`).

### 4.3 `lib/common.sh`

Exit-code constants; `log` (UTC timestamps); `require_env NAME...` (reports missing names only); `mask VALUE` (emits `::add-mask::` in Actions); `emit KEY VALUE` (to `$GITHUB_OUTPUT`); `summary_line` / `summary_table` helpers; `finish STATUS REASON MESSAGE` that emits the standard outputs and exits with the right code. Must be ShellCheck-clean and `set -uo pipefail` safe.

---

## 5. Terraform (`modules/oracle-a1/terraform`)

### 5.1 Versions and backend

- `required_version = ">= 1.12.0, < 2.0.0"` (native OCI backend needs ≥ 1.12). CI pins an exact 1.16.x (§12).
- Provider `oracle/oci`, constraint `~> 9.x` pinned to the current minor (§12). Commit `.terraform.lock.hcl` generated with `terraform providers lock -platform=linux_amd64 -platform=linux_arm64 -platform=darwin_arm64`.
- Native backend, partial configuration; nothing tenancy-specific committed:

```hcl
terraform {
  backend "oci" {
    key                 = "oracle-a1/terraform.tfstate"
    auth                = "APIKey"
    config_file_profile = "DEFAULT"
    # bucket, namespace, region supplied via -backend-config at init
  }
}
```

### 5.2 Provider and retries

```hcl
provider "oci" {
  region              = var.region
  retries_config_file = "${path.module}/retries.json"
}
```

`retries.json`: retry 409 and 429 with backoff (≤ 3 min). Keep **500 short (≤ 60 s total)**: capacity failures arrive as 500s, and the provider's default can retry 500s for several minutes, which wastes the run and hammers the API. Verify the file format and default behaviour (§12).

### 5.3 Variables (with `validation` blocks)

`tenancy_ocid` (must match `^ocid1\.tenancy\.`), `compartment_ocid` (empty ⇒ root), `region` (default `ap-sydney-1`), `instance_availability_domain` (set by run.sh), `fault_domain` (empty or `FAULT-DOMAIN-[1-3]`), `instance_name` (default `oracle-free-a1`), `ocpus` (default **2**, whole number 1–4), `memory_in_gbs` (default **12**, 1–24), `boot_volume_size_in_gbs` (default 50, 50–200), `ssh_public_key` (**key content**, not a path; validate it starts with `ssh-ed25519 `, `ssh-rsa ` or `ecdsa-sha2-`), `os_name` (default `Canonical Ubuntu`), `os_version` (default `24.04`), `existing_subnet_id` (empty ⇒ create network), `ssh_allowed_cidr` (default `0.0.0.0/0`, documented as "narrow this").

### 5.4 Image lookup (never hard-code an image OCID)

```hcl
data "oci_core_images" "arm" {
  compartment_id           = var.tenancy_ocid
  operating_system         = var.os_name
  operating_system_version = var.os_version
  shape                    = "VM.Standard.A1.Flex"
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
  state                    = "AVAILABLE"
  filter {
    name   = "display_name"
    values = ["aarch64"]
    regex  = true
  }
}
```

Add a `check` block asserting at least one image was found, with a helpful error.

### 5.5 Network (`network.tf`)

Only when `existing_subnet_id` is empty: VCN `10.0.0.0/16`, internet gateway, route table `0.0.0.0/0 → IGW`, security list (egress all; ingress TCP 22 from `ssh_allowed_cidr`; ICMP type 3 code 4), **regional** public subnet `10.0.1.0/24`. Freeform tags on everything. README must note that Oracle's Ubuntu images also ship host iptables rules, so opening extra ports later needs changes on the VM too.

### 5.6 Instance (`main.tf`)

```hcl
resource "oci_core_instance" "a1" {
  availability_domain = var.instance_availability_domain
  compartment_id      = local.compartment_ocid
  display_name        = var.instance_name
  shape               = "VM.Standard.A1.Flex"
  fault_domain        = var.fault_domain != "" ? var.fault_domain : null   # omit ⇒ OCI picks any FD with capacity

  shape_config {
    ocpus         = var.ocpus
    memory_in_gbs = var.memory_in_gbs
  }

  source_details {
    source_type             = "image"
    source_id               = data.oci_core_images.arm.images[0].id
    boot_volume_size_in_gbs = var.boot_volume_size_in_gbs
  }

  create_vnic_details {
    subnet_id        = local.subnet_id
    assign_public_ip = true
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key   # raw content, NOT file()
  }

  freeform_tags = { ManagedBy = "Terraform", Hub = "freebie-hub", Module = "oracle-a1" }

  lifecycle {
    # Scheduled runs pass different AD/FD values and Oracle republishes images monthly;
    # none of that may ever trigger a replace of a live instance.
    ignore_changes = [availability_domain, fault_domain, source_details, metadata]
  }
}
```

Document in the module README that because `metadata` is ignored, changing the SSH key later must be done on the VM (or by removing it from `ignore_changes` deliberately).

### 5.7 Outputs

`instance_id`, `instance_name`, `public_ip`, `private_ip`, `availability_domain`, `fault_domain`, `region`, `ocpus`, `memory_in_gbs`, `image_name`, `ssh_command` (`ssh ubuntu@<ip>`; `opc@` for Oracle Linux). No secrets in outputs.

---

## 6. Scripts

- **`modules/oracle-a1/run.sh`** — implements §3 using `lib/common.sh` and `lib/classify.sh`. Inputs via env: `TENANCY_OCID`, `OCPUS` (2), `MEMORY_GB` (12), `CAPACITY_CHECK` (true), `TRY_FAULT_DOMAINS` (false), `SLEEP_BETWEEN` (20), `TF_DIR`. Assumes nothing about the working directory. Tees each Terraform attempt to a per-attempt log under `$RUNNER_TEMP` for classification.
- **`scripts/check-home-region.sh`** — local helper: prints subscribed regions, the home region, its ADs, and a capacity-report probe per AD. Ends with a plain-language verdict ("free A1 is possible only in <home region>").
- **`bootstrap/oracle/create-state-bucket.sh`** — idempotent; creates a private (`NoPublicAccess`), **versioned** bucket; prints the namespace and bucket name to put into GitHub settings. The state bucket is never managed by the module's Terraform.

All scripts: `#!/usr/bin/env bash`, `set -uo pipefail` (explicit exit-code handling around Terraform), ShellCheck clean, no `eval`, all variable expansions quoted, no secrets echoed.

---

## 7. Workflows

### 7.1 `.github/workflows/oracle-a1.yml` (skeleton — refine, pin SHAs)

```yaml
name: oracle-a1

on:
  workflow_dispatch:
    inputs:
      capacity_check:    { type: boolean, default: true,  description: "Gate each attempt on a compute capacity report" }
      try_fault_domains: { type: boolean, default: false, description: "Also try FAULT-DOMAIN-1..3 explicitly" }
  schedule:
    - cron: "4,19,34,49 * * * *"   # every 15 min, off the top of the hour

permissions:
  contents: read
  actions: write          # to disable this workflow after success

concurrency:
  group: oracle-a1
  cancel-in-progress: false

jobs:
  provision:
    if: vars.ORACLE_A1_ENABLED == 'true'
    runs-on: ubuntu-latest
    timeout-minutes: 20
    steps:
      - uses: actions/checkout@<sha>            # vX
      - uses: hashicorp/setup-terraform@<sha>   # v4
        with: { terraform_version: "<pinned 1.16.x>", terraform_wrapper: false }
      - uses: ./.github/actions/setup-oci
        with:
          tenancy-ocid: ${{ secrets.OCI_TENANCY_OCID }}
          user-ocid:    ${{ secrets.OCI_USER_OCID }}
          fingerprint:  ${{ secrets.OCI_FINGERPRINT }}
          private-key:  ${{ secrets.OCI_PRIVATE_KEY }}
          region:       ${{ vars.OCI_REGION || 'ap-sydney-1' }}
      - name: terraform init
        working-directory: modules/oracle-a1/terraform
        run: >
          terraform init -input=false
          -backend-config="bucket=${{ vars.OCI_STATE_BUCKET }}"
          -backend-config="namespace=${{ secrets.OCI_STATE_NAMESPACE }}"
          -backend-config="region=${{ vars.OCI_REGION || 'ap-sydney-1' }}"
      - name: Run module
        id: run
        shell: bash
        env:
          TENANCY_OCID:             ${{ secrets.OCI_TENANCY_OCID }}
          TF_DIR:                   ${{ github.workspace }}/modules/oracle-a1/terraform
          TF_VAR_tenancy_ocid:      ${{ secrets.OCI_TENANCY_OCID }}
          TF_VAR_compartment_ocid:  ${{ secrets.OCI_COMPARTMENT_OCID }}
          TF_VAR_existing_subnet_id: ${{ secrets.OCI_SUBNET_OCID }}
          TF_VAR_region:            ${{ vars.OCI_REGION || 'ap-sydney-1' }}
          TF_VAR_ssh_public_key:    ${{ secrets.ORACLE_A1_SSH_PUBLIC_KEY }}
          TF_VAR_ocpus:             ${{ vars.ORACLE_A1_OCPUS || '2' }}
          TF_VAR_memory_in_gbs:     ${{ vars.ORACLE_A1_MEMORY_GB || '12' }}
          OCPUS:                    ${{ vars.ORACLE_A1_OCPUS || '2' }}
          MEMORY_GB:                ${{ vars.ORACLE_A1_MEMORY_GB || '12' }}
          # inputs are null on schedule; these expressions give the right defaults for both triggers
          CAPACITY_CHECK:    ${{ github.event_name != 'workflow_dispatch' || inputs.capacity_check }}
          TRY_FAULT_DOMAINS: ${{ github.event_name == 'workflow_dispatch' && inputs.try_fault_domains }}
        run: |
          set +e
          ./modules/oracle-a1/run.sh
          rc=$?
          echo "exit_code=$rc" >> "$GITHUB_OUTPUT"
          [[ $rc -eq 0 || $rc -eq 2 || $rc -eq 3 ]] || exit "$rc"
      - name: Notify
        if: always() && (steps.run.outputs.status == 'done' || steps.run.outputs.status == 'fatal' || failure())
        uses: ./.github/actions/notify
        with:
          urls:  ${{ secrets.APPRISE_URLS }}
          title: "oracle-a1: ${{ steps.run.outputs.status || 'failed' }}"
          body:  ${{ steps.run.outputs.message }}
      - name: Disable schedule after success
        if: steps.run.outputs.exit_code == '0'
        env: { GH_TOKEN: "${{ github.token }}" }
        run: gh workflow disable oracle-a1.yml --repo "$GITHUB_REPOSITORY" || echo "::warning::Disable it manually under Actions."
```

Requirements: never notify on `retry` (noise); job summary must be useful for all four statuses; the fatal path's summary must say what to fix.

### 7.2 `.github/actions/setup-oci`

Composite action. Install a **pinned** OCI CLI (prefer `pipx install oci-cli==<ver>` if pipx is on the runner, else `setup-python` + pip). `umask 077`; write `~/.oci/config` and `~/.oci/oci_api_key.pem` (600). Fail fast with a clear `::error::` if the key lacks `-----BEGIN ... PRIVATE KEY-----` (the classic OpenSSH-key mistake). Auth probe: list ADs. Never print the key or config.

### 7.3 `.github/actions/notify`

Composite action wrapping Apprise (pinned version). Inputs `urls`, `title`, `body`. If `urls` is empty, succeed silently. Notification failures must never fail the job.

### 7.4 `.github/workflows/ci.yml`

On push and pull_request: `terraform fmt -check -recursive`; `terraform init -backend=false` + `terraform validate`; ShellCheck on all `*.sh` and shims; actionlint on workflows and composite actions; bats tests. No OCI secrets are available or used in CI.

### 7.5 `.github/dependabot.yml`

Weekly updates for `github-actions` and `terraform` (directory `modules/oracle-a1/terraform`).

---

## 8. Secrets and variables

| Name | Type | Required | Notes |
|---|---|---|---|
| `OCI_TENANCY_OCID` | secret | yes | |
| `OCI_USER_OCID` | secret | yes | dedicated automation user |
| `OCI_FINGERPRINT` | secret | yes | API key fingerprint |
| `OCI_PRIVATE_KEY` | secret | yes | full PEM incl. BEGIN/END lines |
| `OCI_STATE_NAMESPACE` | secret | yes | printed by bootstrap script |
| `OCI_COMPARTMENT_OCID` | secret | no | empty ⇒ root compartment |
| `OCI_SUBNET_OCID` | secret | no | empty ⇒ module creates a VCN |
| `ORACLE_A1_SSH_PUBLIC_KEY` | secret | yes | public key text |
| `APPRISE_URLS` | secret | no | hub-wide notifications, space/comma separated |
| `ORACLE_A1_ENABLED` | variable | yes | must be `true` to run |
| `OCI_REGION` | variable | no | default `ap-sydney-1` |
| `OCI_STATE_BUCKET` | variable | yes | e.g. `freebie-hub-tfstate` |
| `ORACLE_A1_OCPUS` / `ORACLE_A1_MEMORY_GB` | variable | no | defaults 2 / 12; README warns not to exceed the free allowance |

`run.sh` preflight must check all required ones and report missing **names**.

---

## 9. Security requirements

- No credentials, state, tfvars or keys committed (`.gitignore` covers `*.pem`, `*.key`, `.oci/`, `terraform.tfstate*`, `terraform.tfvars`, `*.tfplan`, `.terraform/`). The lock file **is** committed.
- Secrets only via GitHub secrets; never echoed; `::add-mask::` for any derived sensitive value.
- Third-party actions pinned to full commit SHAs with a version comment; Dependabot keeps them fresh.
- Terraform, provider, OCI CLI and Apprise versions pinned.
- Least-privilege IAM (§11) for a dedicated user; the state bucket is private and versioned.
- Workflow `permissions` minimal (`contents: read`, `actions: write` only where needed).
- No `curl | bash`; no interpolation of untrusted input into shell (dispatch inputs are booleans only).
- No secrets in Terraform outputs or the job summary (instance OCID and public IP are acceptable).

---

## 10. Testing

### 10.1 Shims

`tests/shims/oci` and `tests/shims/terraform` are fake executables placed first on `PATH`. Behaviour is selected by `FAKE_SCENARIO` (and optionally `FAKE_ADS="AD-1"` or `"AD-1 AD-2"`). They emit realistic output from `tests/fixtures/` and exit with realistic codes, and record their invocations to a file so tests can assert which commands ran (e.g. "apply was never called").

### 10.2 Fixture logs (approximate — refine if real output is known)

```text
# capacity.log
Error: 500-InternalError, Out of host capacity.
Suggestion: The service for this resource encountered an error. Please contact support for help with service: Core Instance

# limit.log
Error: 400-LimitExceeded, The following service limits were exceeded: standard-a1-memory-count, standard-a1-core-count. Request a service limit increase from the service limits page in the console.

# throttle.log
Error: 429-TooManyRequests, Too many requests for the user

# auth.log
Error: 401-NotAuthenticated, The required information to complete authentication was not provided or was incorrect.

# notfound.log
Error: 404-NotAuthorizedOrNotFound, Authorization failed or requested resource not found.

# lock.log
Error: Error acquiring the state lock

# other.log
Error: 400-InvalidParameter, Invalid subnetId
```

Include a "noisy" fixture where a capacity error is surrounded by long Terraform plan output containing words like `authentication` in resource names, to prove the regexes don't over-match.

### 10.3 Scenario tests (`tests/oracle-a1.bats`)

| # | Scenario | Expected |
|---|---|---|
| A | report AVAILABLE, apply ok | exit 0, `status=done`, outputs populated |
| B | report OUT_OF_HOST_CAPACITY | apply **not** called, exit 2, `reason=no_capacity` |
| C | report AVAILABLE, apply capacity error (1 AD) | exit 2 |
| D | 2 ADs: AD-1 capacity error, AD-2 ok | exit 0, AD-2 used |
| E | apply `LimitExceeded` | exit 1, `reason=limit_exceeded`, no further attempts |
| F | AD listing fails (auth) | exit 1, `reason=auth`, terraform apply never called |
| G | instance in state, plan no changes | exit 0, no create |
| H | instance in state, plan wants replace | exit 1, `reason=refuse_destructive`, apply not called |
| I | instance in state but tainted/TERMINATED | goes to create path |
| J | orphan A1 exists, not in state | exit 1, `reason=orphan` |
| K | apply 429 | exit 2, `reason=throttled`, stops immediately |
| L | state lock error | exit 1, `reason=state_locked` |
| M | unknown error | exit 1, `reason=error` |
| N | required env missing | exit 1, lists names, prints no values |
| O | report inconclusive (CLI error) | apply attempted anyway |
| P | `TRY_FAULT_DOMAINS=true`, first placements capacity, FD-2 ok | exit 0, correct `-var fault_domain` passed |
| Q | `CAPACITY_CHECK=false` | report never called |

Also `tests/classify.bats`: each fixture maps to its category; order precedence (a log containing both capacity and limit text ⇒ `limit`).

---

## 11. Human prerequisites (Andrew does these; document them in README)

1. Home region is `ap-sydney-1` ✔. Confirm with `scripts/check-home-region.sh` if in doubt.
2. Create a group `freebie-hub-automation` and a dedicated user in it; add an **API signing key** (PEM), note the fingerprint.
3. Add the policy from `bootstrap/oracle/iam-policy.txt` (replace `<compartment>`; use `in tenancy` for root):

   ```
   Allow group freebie-hub-automation to inspect availability-domains in tenancy        # verify this is needed/valid
   Allow group freebie-hub-automation to manage compute-capacity-reports in tenancy
   Allow group freebie-hub-automation to read instance-images in tenancy
   Allow group freebie-hub-automation to manage instance-family in compartment <compartment>
   Allow group freebie-hub-automation to manage virtual-network-family in compartment <compartment>
   Allow group freebie-hub-automation to read objectstorage-namespaces in tenancy
   Allow group freebie-hub-automation to read buckets in compartment <compartment> where target.bucket.name = '<state-bucket>'
   Allow group freebie-hub-automation to manage objects in compartment <compartment> where target.bucket.name = '<state-bucket>'
   ```
   (With an existing subnet, `manage virtual-network-family` can drop to `use virtual-network-family`.)
4. Run `bootstrap/oracle/create-state-bucket.sh` locally with an admin CLI profile.
5. Fork/push as a **public** repo; add secrets and variables (§8); set `ORACLE_A1_ENABLED=true`.
6. Run the workflow manually once and read the summary; then let the schedule work.
7. After success: SSH in, keep it doing something useful (idle reclamation), and remember the schedule is now disabled.

---

## 12. Verification checklist (Claude Code, before coding)

Record findings in `docs/DECISIONS.md`.

- [ ] Latest Terraform 1.16.x patch → pin in workflows.
- [ ] Latest `oracle/oci` provider (9.1/9.2 at spec time) → constraint + lock file.
- [ ] Current OCI CLI release → pin.
- [ ] Current majors and SHAs: `actions/checkout`, `hashicorp/setup-terraform` (v4), `actions/setup-python` (if used); whether `pipx` is preinstalled on `ubuntu-latest`.
- [ ] Native `backend "oci"` argument names (`bucket`, `namespace`, `key`, `region`, `auth`, `config_file_profile`) and that locking works.
- [ ] `compute-capacity-report create` syntax, response key names and required IAM resource-type.
- [ ] Exact OCI/Terraform error text for capacity and `LimitExceeded`.
- [ ] `retries_config_file` format; provider default retry behaviour for 500s.
- [ ] Provider behaviour when an instance is terminated out-of-band (dropped from state vs `TERMINATED` in state).
- [ ] `oci_core_images` filter returns Ubuntu 24.04 aarch64 for `VM.Standard.A1.Flex` (docs; can't run live).
- [ ] `gh workflow disable` works with `GITHUB_TOKEN` + `actions: write`.
- [ ] The Always Free A1 allowance is still 2 OCPU / 12 GB.
- [ ] IAM statement for listing ADs is needed/valid.

---

## 13. Known differences from the prototype

- Prototype layout is single-purpose (`terraform/`, `scripts/`); spec uses `modules/oracle-a1/…` + `lib/` + composite actions.
- Prototype's retries.json retried 500 for too long; spec caps 500 retries (§5.2).
- Prototype classified state-lock errors as auth and used broad `401 `/`authentication` patterns; spec adds `lock`, tightens auth, and extracts a pure classifier.
- Prototype had no reconcile safety (§3.3), no orphan guard (§3.4), no tests/shims, no `ci.yml`, no notify, no exit code 3.
- Prototype ran `terraform fmt -check` in the provisioning job; spec moves it to CI.
- Prototype defaulted to Singapore, then Sydney; spec: `ap-sydney-1` via `vars.OCI_REGION`.
- Prototype cron `*/20`; spec `4,19,34,49 * * * *`.
- Prototype grepped `$GITHUB_OUTPUT` for the reason; spec uses step outputs from the module contract.

---

## 14. Definition of done

- [ ] Repo matches §4 layout; `docs/MODULES.md` explains how to add module #2 in under a page, with templates in `docs/module-template/`.
- [ ] `ci.yml` green: fmt, validate, ShellCheck, actionlint, all bats tests (§10).
- [ ] `oracle-a1.yml` skips cleanly when `ORACLE_A1_ENABLED` isn't `true`.
- [ ] Every §10.3 scenario passes with shims.
- [ ] No secrets in repo, logs, outputs or summaries; actions pinned by SHA.
- [ ] README: hub overview, oracle-a1 quickstart (§11), outcomes table (0/1/2/3), troubleshooting (PEM vs SSH key, `LimitExceeded`, home region, state lock, 60-day schedule disable, idle reclamation, Ubuntu iptables).
- [ ] `docs/DECISIONS.md` lists verified versions and any deviations.
- [ ] Summary to me of anything I must verify on the first real run.

---

## 15. Future modules (context only — do not build)

These shape the seams but are out of scope: an OCI usage/free-tier alert module (Actions); cert/domain expiry monitor (Actions); free-game deal notifier via RSS, notify-only (Actions); an idle-keepalive for the A1 box and any account-login game claimers (these belong on the VPS, not in Actions, and carry ToS/account risk). When they arrive they follow §4.2 and get their own workflow file; VPS-side pieces will live under a future `vps/` directory.
