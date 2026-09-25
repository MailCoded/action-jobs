# freebie-hub

Scheduled GitHub Actions jobs that claim and look after free-tier resources, written as
infrastructure-as-code. Each job is a **module**. v1 ships one:

| Module | What it does | Workflow |
|---|---|---|
| [`oracle-a1`](modules/oracle-a1/README.md) | Gets **one** Oracle Cloud Always Free `VM.Standard.A1.Flex` instance (2 OCPU / 12 GB, Ubuntu 24.04 aarch64) in your tenancy's home region, then stops trying. | [`oracle-a1.yml`](.github/workflows/oracle-a1.yml) |

One tenancy, one instance, within the Free Tier rules. No account farming, no keepalive tricks.

## How it works

- A module is `modules/<name>/run.sh` plus its own workflow `.github/workflows/<name>.yml`, so each
  has its own cron, enable switch, logs and manual trigger. The contract (exit codes, outputs, job
  summary) and a short "add a module" guide are in [docs/MODULES.md](docs/MODULES.md).
- Shared pieces: [`lib/common.sh`](lib/common.sh), and the composite actions
  [`setup-oci`](.github/actions/setup-oci) (pinned OCI CLI, credentials, auth probe) and
  [`notify`](.github/actions/notify) (Apprise; does nothing without `APPRISE_URLS`).
- Every module is **off** until its repository variable `<NAME>_ENABLED` is `true`.
- `ci.yml` runs `terraform fmt`/`validate`, ShellCheck, actionlint and the bats tests on every
  push and pull request. It never talks to OCI.
- Deliberate differences from the original spec, and the versions everything is pinned to, are
  recorded in [docs/DECISIONS.md](docs/DECISIONS.md).

**oracle-a1 in one paragraph.** Every 15 minutes a bounded run reads the Terraform state from OCI
Object Storage, asks OCI for a capacity report and, if there is a chance, runs `terraform apply` for
a single A1 instance. "Out of host capacity" is a normal outcome and is retried on the next tick.
Anything else stops loudly with a reason and a "What to fix" section in the job summary. On success
the summary shows the IP and SSH command, a notification goes out (if `APPRISE_URLS` is set), and
the workflow disables itself. A scheduled run never destroys or replaces the instance.

### Outcomes

| Exit | Status | Actions shows | Notification | oracle-a1 examples |
|---|---|---|---|---|
| 0 | `done` | green | yes | instance created, already present, or updated in place; the workflow then disables itself |
| 1 | `fatal` | red | yes | bad credentials, `LimitExceeded`, state lock, orphan instance, refused replace |
| 2 | `retry` | green with a warning | no | out of host capacity, throttled, instance still terminating |
| 3 | `skipped` | green | no | not used by oracle-a1; with `ORACLE_A1_ENABLED` unset the whole job is skipped instead |

A failure in an earlier step (for example `setup-oci` rejecting the key) is also red and notifies
with the title `oracle-a1: failed`. Every reason and its fix is listed in
[modules/oracle-a1/README.md](modules/oracle-a1/README.md#statuses-and-reasons).

## oracle-a1 quickstart

You need a local OCI CLI with a profile for **your own admin user** (`oci setup config`; the
examples call it `admin`). It is used only for the one-off steps 1, 3 and 4, run from the repository
root in a shell where you have done `export TENANCY_OCID=ocid1.tenancy.oc1..xxxx`.

1. **Confirm the home region.** Always Free A1 can only be launched in the tenancy's home region,
   and the home region can never be changed. It is shown in the Console under *Profile → Tenancy*,
   or run:

   ```sh
   OCI_CLI_PROFILE=admin modules/oracle-a1/scripts/check-home-region.sh
   ```

   It lists the subscribed regions, the home region, its availability domains and a capacity report
   per AD, and ends with a verdict. If the home region is not `ap-sydney-1`, set the `OCI_REGION`
   variable to it in step 7.

2. **Create the automation group and user.** In the Console (*Identity & Security → Domains →
   Default domain*): create the group `freebie-hub-automation` and a dedicated user (not your admin
   login) in it. On that user, open *API keys → Add API key → Generate API key pair*, download the
   **private key** (`.pem`), click *Add*, and copy the fingerprint. Note the user OCID and the
   tenancy OCID. This PEM is an API signing key, **not** an SSH key.

3. **Create the state bucket** (private, versioned, never managed by Terraform; safe to re-run):

   ```sh
   OCI_CLI_PROFILE=admin bootstrap/oracle/create-state-bucket.sh
   ```

   Optional: `COMPARTMENT_OCID` (default root), `BUCKET` (default `freebie-hub-tfstate`),
   `OCI_REGION` (default `ap-sydney-1`; the bucket must be in the region the workflow uses). It
   prints the values for `OCI_STATE_BUCKET`, `OCI_STATE_NAMESPACE` and the policy's
   `<bucket-location>`.

4. **Add the IAM policy** from [`bootstrap/oracle/iam-policy.txt`](bootstrap/oracle/iam-policy.txt)
   in the **root** compartment. The `#` lines explain each statement; OCI policies have no comment
   syntax, so submit only the `Allow` lines. Placeholders: `<location>` is where the instance lives
   (`tenancy`, or `compartment id ocid1.compartment.oc1..xxxx`), `<bucket-location>` is the bucket's
   compartment in the same form, `<state-bucket>` is the bucket name.

   ```sh
   statements="$(sed -e 's/<location>/tenancy/' -e 's/<bucket-location>/tenancy/' \
       -e 's/<state-bucket>/freebie-hub-tfstate/' bootstrap/oracle/iam-policy.txt |
     grep '^Allow ' | jq -Rsc 'split("\n") | map(select(length > 0))')"
   jq -r '.[]' <<<"$statements"   # review: six statements
   oci --profile admin iam policy create --compartment-id "$TENANCY_OCID" \
     --name freebie-hub-automation --description "freebie-hub oracle-a1 automation" \
     --statements "$statements"
   ```

   Or paste the `Allow` lines into *Identity & Security → Policies → Create policy → manual editor*.
   With an existing subnet (`OCI_SUBNET_OCID`), `manage virtual-network-family` can drop to
   `use virtual-network-family`, granted in the subnet's compartment (and in the instance
   compartment if that differs). The file also lists two optional statements (`inspect volumes`,
   and a tag-namespace statement that is only needed if a launch fails on Oracle-Tags defaults).

5. **Make an SSH key pair** for logging in to the VM, e.g.
   `ssh-keygen -t ed25519 -f ~/.ssh/oracle-a1 -C oracle-a1`. The **public** half
   (`~/.ssh/oracle-a1.pub`) goes into `ORACLE_A1_SSH_PUBLIC_KEY`.

6. **Put the repository on GitHub as public** (fork or push). Public repositories get standard
   runners for free; see [private repositories](#private-repository-minutes). **If you forked:**
   GitHub disables workflows in forks, so open the fork's *Actions* tab, enable workflows, and enable
   `oracle-a1` if it is listed as disabled.

7. **Add the secrets and variables** below under *Settings → Secrets and variables → Actions*. Set
   `ORACLE_A1_ENABLED=true` last.

8. **Run it once by hand:** *Actions → oracle-a1 → Run workflow* (the defaults are fine) and read
   the job summary. `retry (no_capacity)` means everything works and OCI simply has no capacity right
   now: leave it to the schedule. Anything red has a "What to fix" section.

9. **After success:** the summary shows the IP and `ssh ubuntu@<ip>` (use `-i ~/.ssh/oracle-a1`).
   The workflow is now disabled, manual runs included. Keep the VM doing something useful
   ([idle reclamation](#idle-reclamation)).

### Secrets and variables

| Name | Type | Required | Notes |
|---|---|---|---|
| `OCI_TENANCY_OCID` | secret | yes | `ocid1.tenancy.oc1..…` |
| `OCI_USER_OCID` | secret | yes | the dedicated automation user, `ocid1.user.oc1..…` |
| `OCI_FINGERPRINT` | secret | yes | API key fingerprint `aa:bb:…` (upper case is accepted) |
| `OCI_PRIVATE_KEY` | secret | yes | full, unencrypted API key PEM including the `BEGIN`/`END` lines |
| `OCI_STATE_NAMESPACE` | secret | yes | printed by `create-state-bucket.sh` |
| `OCI_COMPARTMENT_OCID` | secret | no | empty ⇒ root compartment |
| `OCI_SUBNET_OCID` | secret | no | existing **public** subnet; empty ⇒ the module creates a small VCN |
| `ORACLE_A1_SSH_PUBLIC_KEY` | secret | yes | public key text starting `ssh-ed25519 `, `ssh-rsa ` or `ecdsa-sha2-` |
| `APPRISE_URLS` | secret | no | hub-wide notifications, space/comma separated [Apprise URLs](https://github.com/caronc/apprise/wiki) (e.g. `ntfy://…`, `tgram://…`, `discord://…`) |
| `ORACLE_A1_ENABLED` | variable | yes | must be `true` to run |
| `OCI_REGION` | variable | no | default `ap-sydney-1`; must be the home region |
| `OCI_STATE_BUCKET` | variable | yes | e.g. `freebie-hub-tfstate` |
| `ORACLE_A1_OCPUS` / `ORACLE_A1_MEMORY_GB` | variable | no | defaults `2` / `12`. **Do not exceed 2 / 12**: that is the whole Always Free A1 allowance |

Manual runs have two inputs: `capacity_check` (default on: gate each attempt on a capacity report)
and `try_fault_domains` (default off: also try `FAULT-DOMAIN-1..3` explicitly). Scheduled runs use
the defaults.

## Troubleshooting

Start with the job summary of the failed run: the status line gives the reason, "What to fix" the
next step, and a collapsed log tail the raw error.

### Runs show as "Skipped"

`ORACLE_A1_ENABLED` is not `true`, so the job-level `if:` skips the job. No runner starts and no
minutes are used, but a skipped run appears every 15 minutes. Set the variable to `true` to start,
or disable the workflow in the *Actions* tab to silence it.

### `setup-oci` fails, or reason `auth`: PEM vs SSH key

- `OCI_PRIVATE_KEY` must be the **API signing key** from step 2 (`-----BEGIN PRIVATE KEY-----` or
  `-----BEGIN RSA PRIVATE KEY-----`). `setup-oci` rejects an OpenSSH key
  (`BEGIN OPENSSH PRIVATE KEY`), a public key, an incomplete PEM and an encrypted key before calling
  OCI. Decrypt one with `openssl pkey -in encrypted.pem -out oci_api_key.pem`.
- `ORACLE_A1_SSH_PUBLIC_KEY` is the other way round: SSH **public** key text, not a path and not a
  private key.
- `OCI_FINGERPRINT` must belong to that API key, and `OCI_USER_OCID` / `OCI_TENANCY_OCID` must be the
  automation user and its tenancy. A newly added key can take a minute or two to work.
- A 404 `NotAuthorizedOrNotFound` usually means a missing policy statement: check that the policy
  exists in the **root** compartment and names the right group.
- `BucketNotFound` during `terraform init` means `OCI_STATE_BUCKET` / `OCI_STATE_NAMESPACE` /
  `OCI_REGION` do not match the bucket, or the `manage objects` statement is missing.

### `limit_exceeded` (LimitExceeded)

Retrying cannot help until the allowance is free again, so the run is fatal. 2 OCPU / 12 GB is the
whole Always Free A1 allowance, so any other A1 usage blocks the launch:

- another `VM.Standard.A1.Flex` instance in **any** compartment (the orphan guard only checks the
  target compartment; use the compartment picker under *Compute → Instances*);
- an A1 instance that is still `TERMINATING`: it holds the allowance until it is `TERMINATED`;
- `ORACLE_A1_OCPUS` / `ORACLE_A1_MEMORY_GB` above 2 / 12, alone or added to another instance.

Remove or shrink the other instance, wait for it to reach `TERMINATED`, then run the workflow again.

### Home region

Free A1 exists only in the home region. If `OCI_REGION` points anywhere else the run fails (`auth`,
or no availability domains) or cannot get a free instance. Run `check-home-region.sh` (step 1) and set
`OCI_REGION` to the region it names.

### `state_locked`: stuck state lock

A run that was killed mid-operation (cancelled, timed out) can leave the lock object behind. Make sure
no oracle-a1 run or local Terraform command is in progress, then release it with the lock ID from the
job summary:

```sh
terraform -chdir=modules/oracle-a1/terraform init -backend-config="bucket=freebie-hub-tfstate" \
  -backend-config="namespace=<OCI_STATE_NAMESPACE>" -backend-config="region=ap-sydney-1"
terraform -chdir=modules/oracle-a1/terraform force-unlock -force <LOCK_ID>
```

This needs a `[DEFAULT]` profile in `~/.oci/config` that may manage objects in the bucket (see
[Running locally](#running-locally)).

### `refuse_destructive`

A scheduled run never destroys or replaces the instance. Two causes:

- **The instance is tainted but alive**, typically a launch whose wait for `RUNNING` timed out but
  which came up later. If it is healthy, keep it:
  `terraform -chdir=modules/oracle-a1/terraform untaint oci_core_instance.a1` (after the `init`
  above). If you want a fresh one instead, terminate it in the Console; the next run creates a new one.
- **The plan wants to replace or delete it**, usually because a setting such as `OCI_SUBNET_OCID`
  changed after creation. Revert the change, or apply it deliberately from your machine after
  reading `terraform plan`.

### `orphan`

Terraform state is empty but the target compartment already has an A1 instance (lost state, or one
created by hand). Terminate it in the Console, or adopt it: the job summary prints the exact
`terraform import` commands for the instance and, if the module created the network, the VCN,
gateway, route table, security list and subnet. Run them with the same `OCI_REGION`,
`OCI_COMPARTMENT_OCID` and `OCI_SUBNET_OCID` as the workflow (the printed `export` line has slots for
them); otherwise the import targets the wrong region or the plan proposes a replacement. Afterwards
`terraform plan` must show no delete on `oci_core_instance.a1`.

### `terminating`

The tracked instance, or an untracked A1 in the compartment, is still `TERMINATING`. Nothing to do:
the next scheduled run continues once OCI finishes.

### The schedule stopped after success, and "Run workflow" is gone

That is by design: after `done` the workflow runs `gh workflow disable oracle-a1.yml`, which disables
the **whole** workflow, including manual dispatch. To run it again (for example after terminating the
instance): `gh workflow enable oracle-a1.yml`, or *Actions → oracle-a1 → Enable workflow*. The file
must keep the name `oracle-a1.yml` on the default branch for this to work.

### The schedule stopped after 60 days

GitHub disables scheduled workflows in public repositories after 60 days without repository activity.
GitHub's docs do not define "activity" (community reports say commits count). Re-enable it with
`gh workflow enable oracle-a1.yml` or from the *Actions* tab. This repository deliberately does not
make keepalive commits. GitHub schedules are best effort anyway: runs can be delayed or dropped,
especially around the top of the hour, which is why the cron uses minutes 4, 19, 34 and 49. GitHub
sends its own failure emails for scheduled runs to whoever last changed the cron or re-enabled the
workflow.

### Idle reclamation

Oracle may reclaim an Always Free compute instance that is idle over a 7-day period: 95th-percentile
CPU utilisation below 20 %, network utilisation below 20 %, and memory utilisation below 20 % (the
memory condition applies to A1 only). Give the VM real work. Keeping it busy is out of scope for this
repository.

### Opening more ports (Ubuntu iptables)

Oracle's platform images ship host firewall rules that allow only SSH (plus the rules the iSCSI boot
volume needs). Opening a port takes two changes:

1. **Network:** an ingress rule for the port. The module's security list is owned by Terraform, so a
   rule added in the Console is removed again by the next reconcile run; add it in
   `modules/oracle-a1/terraform/network.tf`, or use your own subnet via `OCI_SUBNET_OCID`.
2. **On the VM:** edit `/etc/iptables/rules.v4`, insert a rule such as
   `-A INPUT -p tcp -m state --state NEW -m tcp --dport 443 -j ACCEPT` after the port 22 rule and
   before the final `REJECT` line, then run `sudo iptables-restore < /etc/iptables/rules.v4`. **Never
   use `ufw`** and never remove the `169.254.x.x` rules: that can break the boot volume connection and
   stop the instance from booting.

### The Always Free allowance

Oracle's Always Free documentation (updated around 2026-06-12) gives A1 as "the first 1,500 OCPU
hours and 9,000 GB hours per month", which it calls equivalent to 2 OCPUs and 12 GB of memory
(previously 3,000 / 18,000, i.e. 4 OCPU / 24 GB). A 2 OCPU / 12 GB instance running all month stays
under it: 1,488 OCPU hours and 8,928 GB hours in a 31-day month. Users report an Oracle email
(received 2026-08-05) announcing enforcement from 2026-08-18, after which over-limit A1 instances
were disabled or terminated; that date does not appear in Oracle's documentation. Stay at 2 / 12 or
below across the whole tenancy. The boot volume (50 GB by default) counts towards the 200 GB of
Always Free block storage.

### Private repository minutes

In a public repository standard runners are free. In a private repository every run is billed against
the free minutes (2,000 per month on GitHub Free), and at 96 runs a day those are gone in about a
week. Keep the repository public; secrets stay encrypted and are never printed.

### No public IP, or errors about tag namespaces

- `done` but "no public IP was reported": the subnet is not public, or the network statement in the
  policy is missing, so the provider cannot read the VNIC.
- A launch or VCN create that fails with an error about tag namespaces: add the optional
  `oracle-tags` statement from `iam-policy.txt`.

## Running locally

`run.sh` runs outside Actions too: the summary goes to stdout, logs to stderr, and step outputs are
discarded. It needs bash 4+, `jq`, Terraform ≥ 1.12 (CI uses 1.16.4) and the OCI CLI (CI uses
3.94.0), plus a **`[DEFAULT]` profile in `~/.oci/config`** for a user that has the policy above.
Terraform's backend and provider always read that profile, whatever `OCI_CLI_CONFIG_FILE` or
`OCI_CLI_PROFILE` say, so leave `OCI_CLI_PROFILE` unset or the OCI CLI calls would use a different
identity.

```sh
export TENANCY_OCID=ocid1.tenancy.oc1..xxxx
export OCI_STATE_BUCKET=freebie-hub-tfstate
export OCI_STATE_NAMESPACE=<namespace>
export TF_VAR_ssh_public_key="$(cat ~/.ssh/oracle-a1.pub)"
export OCI_REGION=ap-sydney-1                 # optional, this is the default
modules/oracle-a1/run.sh; echo "exit $?"
```

Optional: `TF_VAR_compartment_ocid`, `TF_VAR_existing_subnet_id`, `OCPUS`, `MEMORY_GB`,
`CAPACITY_CHECK`, `TRY_FAULT_DOMAINS`, `SLEEP_BETWEEN`, `MAX_RUN_SECONDS`, `LOCK_TIMEOUT`, `TF_DIR`
(see the [module README](modules/oracle-a1/README.md#inputs)). A local run uses the same remote
state and lock as the workflow and **can create the instance**: don't run it while a workflow run is
in progress. The test suite runs offline with shims: `bats tests/`.

## Repository layout

```
.github/
  actions/setup-oci/     OCI CLI install, ~/.oci/config + PEM, auth probe
  actions/notify/        Apprise notifications (no-op without APPRISE_URLS)
  workflows/oracle-a1.yml  schedule + manual dispatch for the oracle-a1 module
  workflows/ci.yml       lint and tests; never touches OCI
lib/common.sh            shared helpers: exit codes, logging, outputs, job summary
modules/oracle-a1/       run.sh, lib/classify.sh, scripts/check-home-region.sh, terraform/
bootstrap/oracle/        create-state-bucket.sh, iam-policy.txt (one-off, run with an admin profile)
tests/                   bats tests, shims and fixture logs
docs/                    MODULES.md, module-template/, DECISIONS.md
```

## Security

- No credentials, state, tfvars or keys in the repository (`.gitignore`); the Terraform lock file is
  committed.
- Secrets reach the job only as GitHub secrets and are never printed; missing settings are reported
  by name.
- Third-party actions are pinned to full commit SHAs; Terraform, the provider, the OCI CLI and
  Apprise are pinned too.
- A dedicated least-privilege user; a private, versioned state bucket; minimal workflow permissions
  (`contents: read`, plus `actions: write` only for oracle-a1's self-disable).
