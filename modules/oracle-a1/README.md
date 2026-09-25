# oracle-a1

Gets **one** Oracle Cloud Always Free `VM.Standard.A1.Flex` instance (default 2 OCPU / 12 GB,
Ubuntu 24.04 aarch64) in the tenancy's home region. Terraform owns the instance and keeps its state in
OCI Object Storage, so every ephemeral runner sees the same truth. `run.sh` only decides *where* to
try and *what an error means*. Setup steps are in the [hub README](../../README.md#oracle-a1-quickstart).

## What a run does

```
preflight           required settings (names only), terraform/oci/jq on PATH, OCI CLI config, value checks
list ADs            oci iam availability-domain list; doubles as the auth probe
terraform init      remote state (-lockfile=readonly), then terraform validate
instance in state?
├─ yes: reconcile   terraform plan against the refreshed state
│    ├─ gone from OCI (terminated out-of-band) ......... create path
│    ├─ state TERMINATED ............................... terraform state rm, create path
│    ├─ state TERMINATING .............................. retry (terminating)
│    ├─ tainted but alive .............................. fatal (refuse_destructive), untaint guidance
│    ├─ no changes (or only output values change) ...... done (instance_present)
│    ├─ plan deletes or replaces the instance .......... fatal (refuse_destructive)
│    └─ other changes .................................. apply the saved plan, done (instance_updated)
└─ no: create path
     ├─ orphan guard: untracked A1 in the compartment .. fatal (orphan); only TERMINATING ones: retry (terminating)
     └─ for each AD
          ├─ capacity report (CAPACITY_CHECK) ........... every entry OUT_OF_HOST_CAPACITY / HARDWARE_NOT_SUPPORTED:
          │                                               skip the AD; error, empty or unknown: attempt anyway
          └─ for each placement: no fault domain, then FAULT-DOMAIN-1..3 if TRY_FAULT_DOMAINS
               ├─ MAX_RUN_SECONDS passed ................ retry (no_capacity)
               ├─ sleep SLEEP_BETWEEN (not before the first attempt)
               └─ terraform apply
                    ├─ ok ............................... done (instance_created)
                    ├─ out of host capacity ............. next placement (retry if the failed launch left an instance in state)
                    ├─ throttled ........................ retry (throttled), immediately
                    ├─ other, but the launch left an instance in state .. retry (launch_failed)
                    └─ limit / lock / auth / other ...... fatal
     all placements tried ............................... retry (no_capacity)
```

Every Terraform and OCI error is classified by [`lib/classify.sh`](lib/classify.sh), in this order so a
limit error can never pass for a capacity miss: limit → lock → auth → capacity → throttle → other.
Each placement is tried at most once per run.

## Inputs

`run.sh` takes no arguments; it is configured only by environment variables and works from any
directory.

| Variable | Default | Notes |
|---|---|---|
| `TENANCY_OCID` | **required** | Also the compartment for the image lookup and the capacity report, and the default instance compartment. |
| `OCI_STATE_BUCKET` | **required** | State bucket (`-backend-config`). |
| `OCI_STATE_NAMESPACE` | **required** | Object Storage namespace (`-backend-config`). |
| `TF_VAR_ssh_public_key` | **required** | SSH public key text. |
| `OCI_REGION` | `ap-sydney-1` | Must be the home region. Used for the OCI CLI calls, Terraform and the backend. |
| `TF_VAR_compartment_ocid` | empty (root) | Compartment for the instance and network; also the one the orphan guard lists. |
| `TF_VAR_existing_subnet_id` | empty | Existing public subnet; empty creates a VCN. |
| `OCPUS` | `2` | Whole number 1–4; a warning above 2. |
| `MEMORY_GB` | `12` | Whole number 1–24; a warning above 12. |
| `CAPACITY_CHECK` | `true` | `true`/`false`: gate each AD on a capacity report. |
| `TRY_FAULT_DOMAINS` | `false` | `true`/`false`: after "any fault domain", also try `FAULT-DOMAIN-1..3`. |
| `SLEEP_BETWEEN` | `20` | Seconds between attempts. |
| `MAX_RUN_SECONDS` | `600` | No new attempt starts after this. With the 10-minute create timeout and the 30-minute job timeout, a late attempt still finishes before the job is killed. |
| `LOCK_TIMEOUT` | `60s` | `-lock-timeout` for plan, apply and `state rm`. |
| `TF_DIR` | `terraform/` next to `run.sh` | |
| `OCI_CLI_CONFIG_FILE` | `~/.oci/config` | Must exist. Terraform itself always reads the `[DEFAULT]` profile of `~/.oci/config`. |

`run.sh` exports `TF_VAR_tenancy_ocid`, `TF_VAR_region`, `TF_VAR_ocpus` and `TF_VAR_memory_in_gbs`
from `TENANCY_OCID`, `OCI_REGION`, `OCPUS` and `MEMORY_GB`, so the capacity report and Terraform
always agree; values you set for those four are overwritten. A `terraform.tfvars` (or
`*.auto.tfvars`) in `TF_DIR` would take precedence over those exports, so `run.sh` refuses to run
while one is present. Per-attempt logs go to a directory under
`$RUNNER_TEMP` (or `$TMPDIR`); its path is logged at the start.

### Where the workflow gets them

| Repository setting | Type | Becomes |
|---|---|---|
| `OCI_TENANCY_OCID` | secret | `TENANCY_OCID`, and `setup-oci`'s `tenancy-ocid` |
| `OCI_USER_OCID`, `OCI_FINGERPRINT`, `OCI_PRIVATE_KEY` | secrets | `setup-oci` only: written to `~/.oci/config` and `~/.oci/oci_api_key.pem` (mode 600) |
| `OCI_REGION` | variable | `OCI_REGION` and `setup-oci`'s `region` (default `ap-sydney-1`) |
| `OCI_STATE_BUCKET` | variable | `OCI_STATE_BUCKET` |
| `OCI_STATE_NAMESPACE` | secret | `OCI_STATE_NAMESPACE` |
| `OCI_COMPARTMENT_OCID` | secret | `TF_VAR_compartment_ocid` |
| `OCI_SUBNET_OCID` | secret | `TF_VAR_existing_subnet_id` |
| `ORACLE_A1_SSH_PUBLIC_KEY` | secret | `TF_VAR_ssh_public_key` |
| `ORACLE_A1_OCPUS` / `ORACLE_A1_MEMORY_GB` | variables | `OCPUS` / `MEMORY_GB` (defaults 2 / 12) |
| dispatch inputs `capacity_check` / `try_fault_domains` | inputs | `CAPACITY_CHECK` / `TRY_FAULT_DOMAINS` (scheduled runs: `true` / `false`) |
| `ORACLE_A1_ENABLED` | variable | the job's `if:`; anything but `true` skips the job |
| `APPRISE_URLS` | secret | the `notify` action |

## Statuses and reasons

Every run ends with exactly one `status` and `reason`. The job summary repeats them, and fatal runs
add a "What to fix" section and a log tail.

| Status (exit) | Reason | Meaning | What to do |
|---|---|---|---|
| done (0) | `instance_created` | This run launched the instance. | SSH in. The workflow disables itself. |
| done (0) | `instance_present` | The tracked instance exists and no resource changes (output values may be refreshed, e.g. the image name once that build rotates out of the image list). | Nothing. |
| done (0) | `instance_updated` | Non-destructive changes (e.g. tags, security-list rules) were applied. | Nothing. |
| retry (2) | `no_capacity` | Out of host capacity everywhere tried, all capacity reports negative, `MAX_RUN_SECONDS` reached, or a launch was accepted and then failed with capacity wording (the next run cleans up the record). | Nothing; the next tick retries. |
| retry (2) | `launch_failed` | OCI accepted the launch, then it failed without capacity wording (for example an empty work-request message), leaving the failed instance in state. | Nothing; the next run cleans up a terminated record, or reports `refuse_destructive` if the instance turned out alive. |
| retry (2) | `throttled` | OCI returned 429 TooManyRequests. The run stops instead of pushing on. | Nothing, unless it repeats for hours. |
| retry (2) | `terminating` | The tracked instance, or an untracked A1 in the compartment, is still `TERMINATING`. | Nothing; creating now would hit `LimitExceeded`. |
| fatal (1) | `missing_config` | A required setting is missing (listed by name), or the OCI CLI config file does not exist. | Add the named secret/variable. |
| fatal (1) | `missing_tool` | `terraform`, `oci` or `jq` is not on `PATH`. | Workflow: check the setup steps. Locally: install it. |
| fatal (1) | `invalid_config` | A value is malformed: tenancy OCID, `OCPUS` 1–4, `MEMORY_GB` 1–24, booleans, `SLEEP_BETWEEN`, `MAX_RUN_SECONDS`, region, SSH public key (must start with `ssh-ed25519 `, `ssh-rsa ` or `ecdsa-sha2-`), `TF_DIR` has no `.tf` files, or `TF_DIR` contains a `terraform.tfvars`/`*.auto.tfvars` file that would override `run.sh`. | Fix the value shown. |
| fatal (1) | `auth` | Listing ADs failed or returned none, or OCI answered 401/403/`NotAuthorizedOrNotFound`, `BucketNotFound`, or a key/config error. | PEM vs SSH key, fingerprint, OCIDs, home region, policy in the root compartment, bucket/namespace. |
| fatal (1) | `limit_exceeded` | `LimitExceeded`/`QuotaExceeded`/`standard-a1-*-count`: the A1 allowance is in use. | Find the other A1 in **any** compartment (or one still terminating); keep 2 / 12 or less. |
| fatal (1) | `state_locked` | Another operation holds the state lock (`IfNoneMatchFailed`), even after waiting `LOCK_TIMEOUT`. | Make sure nothing is running, then `terraform force-unlock -force <ID>` (the summary prints the command and ID). |
| fatal (1) | `refuse_destructive` | The instance is tainted but alive, or the plan would delete or replace it. | `terraform untaint oci_core_instance.a1` if it is healthy, or revert the change that forces a replacement. |
| fatal (1) | `orphan` | State is empty but the compartment has a live A1 instance. | Terminate it, or `terraform import` it (the summary prints the commands, including the network). |
| fatal (1) | `error` | Anything else: e.g. a Terraform variable validation failure (such as a malformed `OCI_COMPARTMENT_OCID` or `OCI_SUBNET_OCID`), no matching image, a lock file mismatch, an unexpected OCI error. | Read the log tail; it will not fix itself. |
| skipped (3) | — | Never returned by this module. A disabled module skips the whole job instead. | |

## Outputs

Always: `status`, `reason`, `message`. On `done` also:

| Output | Example |
|---|---|
| `public_ip` | `203.0.113.10` |
| `instance_id` | `ocid1.instance.oc1.ap-sydney-1.…` |
| `availability_domain` | `Qxyz:AP-SYDNEY-1-AD-1` |
| `fault_domain` | `FAULT-DOMAIN-2` |
| `image_name` | `Canonical-Ubuntu-24.04-aarch64-2026.09.18-0` |
| `ocpus` / `memory_in_gbs` | `2` / `12` |
| `ssh_command` | `ssh ubuntu@203.0.113.10` |

The job summary shows the same table. No secrets appear in outputs or the summary.

## Terraform

Files in [`terraform/`](terraform): `versions.tf` (Terraform `>= 1.12.0, < 2.0.0`, `oracle/oci ~> 9.3`),
`backend.tf` (native `oci` backend, key `oracle-a1/terraform.tfstate`; bucket, namespace and region
come from `-backend-config`), `providers.tf` + `retries.json`, `data.tf` (image lookup), `network.tf`,
`main.tf`, `outputs.tf`, the committed `.terraform.lock.hcl`, and `terraform.tfvars.example` for local
experiments.

| Variable | Default | Set by | Notes |
|---|---|---|---|
| `tenancy_ocid` | — | `run.sh` | Must start with `ocid1.tenancy.` |
| `compartment_ocid` | `""` (root) | `OCI_COMPARTMENT_OCID` | |
| `region` | `ap-sydney-1` | `run.sh` | |
| `instance_availability_domain` | `""` | `run.sh`, per attempt | Ignored after creation. |
| `fault_domain` | `""` (OCI picks) | `run.sh`, per attempt | Empty or `FAULT-DOMAIN-1..3`; ignored after creation. |
| `instance_name` | `oracle-free-a1` | — | Also prefixes the network resource names. |
| `ocpus` | `2` | `run.sh` | Whole number 1–4. |
| `memory_in_gbs` | `12` | `run.sh` | 1–24. |
| `boot_volume_size_in_gbs` | `50` | — | Whole number 50–200. |
| `ssh_public_key` | — | `ORACLE_A1_SSH_PUBLIC_KEY` | Key text starting `ssh-ed25519 `, `ssh-rsa ` or `ecdsa-sha2-`. |
| `os_name` / `os_version` | `Canonical Ubuntu` / `24.04` | — | |
| `existing_subnet_id` | `""` (create a VCN) | `OCI_SUBNET_OCID` | Must start with `ocid1.subnet.` |
| `ssh_allowed_cidr` | `0.0.0.0/0` | — | Source of the SSH rule in the created security list. **Narrow this** to your address. |

Variables marked "—" are not wired to repository settings: change the default in `variables.tf`, or
add a `TF_VAR_<name>` line to the workflow's run step.

Outputs: `instance_id`, `instance_name`, `public_ip`, `private_ip`, `availability_domain`,
`fault_domain`, `region`, `ocpus`, `memory_in_gbs`, `image_name`, `ssh_command` (`ubuntu@` for Ubuntu
images, `opc@` otherwise).

## Behaviour notes

- **Never destroys or replaces.** The instance has
  `ignore_changes = [availability_domain, fault_domain, source_details, metadata]`: new AD/FD values
  on every run and Oracle's monthly image releases can never trigger a replacement. The consequence:
  changing `ORACLE_A1_SSH_PUBLIC_KEY` (or `boot_volume_size_in_gbs`, `os_name`, `os_version`) later
  does nothing to the existing VM. To change the SSH key, edit `~/.ssh/authorized_keys` on the VM, or
  remove `metadata` from `ignore_changes` deliberately and apply from your machine. The `ssh_command`
  output takes its login user from the image the VM was built from while that build is still listed,
  and from `os_name` after that, so leave `os_name` alone while the instance exists.
- **Replacement-forcing changes are refused.** For example, setting or changing `OCI_SUBNET_OCID`
  after creation makes the plan replace the instance, and the run stops with `refuse_destructive`.
- **Image.** Newest `AVAILABLE` Canonical Ubuntu 24.04 aarch64 platform image for A1, looked up on
  every run, never a hard-coded OCID. Minimal and GPU builds are excluded (Oracle says not to use
  Minimal on Arm). No match stops the plan with an explicit error. `image_name` reports the image the
  instance was actually built from (its OCID once that build leaves Oracle's list).
- **Storage.** The boot volume (50 GB default) counts towards the 200 GB of Always Free block storage,
  shared by all boot and block volumes. Boot volumes left behind by other instances count too.
- **Network.** Only without `OCI_SUBNET_OCID`: VCN `10.0.0.0/16`, internet gateway, route table
  (`0.0.0.0/0` → gateway), security list (all egress; TCP 22 from `ssh_allowed_cidr`; ICMP type 3
  code 4), and a regional public subnet `10.0.1.0/24`. Terraform owns these: Console edits are
  reverted by the next reconcile run. Oracle's Ubuntu images also filter ports with iptables on the
  VM (see [opening ports](../../README.md#opening-more-ports-ubuntu-iptables)).
- **Tags.** Freeform tags `ManagedBy=Terraform`, `Hub=freebie-hub`, `Module=oracle-a1` on everything.
- **Capacity report.** Advisory only: it is a snapshot and has been reported inaccurate, so the apply
  result is what counts. It always uses the root compartment (an OCI requirement) and reads every
  entry it returns.
- **Bounded time.** The provider waits at most 10 minutes for a launch to reach `RUNNING` (the default
  of 45 would outlive the job). `retries.json` caps provider retries at about 165 s for 409/429 and
  45 s for 500s; an "Out of host capacity" 500 is never retried by the provider. `run.sh` starts no
  new attempt after `MAX_RUN_SECONDS`.
- **Orphan guard scope.** It lists only the target compartment. An A1 elsewhere in the tenancy shows up
  as `limit_exceeded` instead.
- **One instance.** The configuration has a single `oci_core_instance.a1` and no `count`; nothing in
  the module can create a second one.
- **Removing it.** Scheduled runs never delete anything. To tear down, run `terraform destroy` from
  your machine against the same backend; re-enable the workflow if you want a new instance.

## Troubleshooting

The reasons table above gives the fix for each outcome. The hub README covers the platform side:
[PEM vs SSH key](../../README.md#setup-oci-fails-or-reason-auth-pem-vs-ssh-key),
[`LimitExceeded`](../../README.md#limit_exceeded-limitexceeded),
[home region](../../README.md#home-region),
[stuck state lock](../../README.md#state_locked-stuck-state-lock),
[schedule disabled](../../README.md#the-schedule-stopped-after-success-and-run-workflow-is-gone),
[idle reclamation](../../README.md#idle-reclamation) and
[iptables](../../README.md#opening-more-ports-ubuntu-iptables).

- **The image name in the summary is not `Canonical-Ubuntu-24.04-aarch64-…`.** Check `os_name` and
  `os_version`; the first live run is where the image query is proven.
- **`done` but no public IP.** The subnet must be public (`OCI_SUBNET_OCID`), and the network policy
  statement must be present so the provider can read the VNIC.
- **`error` with "Invalid value for variable".** A Terraform validation failed; the log tail names the
  variable (usually `compartment_ocid` or `existing_subnet_id`; the SSH key is checked earlier and
  ends as `invalid_config`).
- **A launch fails on tag namespaces.** Add the optional `oracle-tags` statement from
  [`iam-policy.txt`](../../bootstrap/oracle/iam-policy.txt).
- **Run it by hand.** See [Running locally](../../README.md#running-locally), and
  `modules/oracle-a1/scripts/check-home-region.sh` for the home region, its ADs and a capacity probe.
