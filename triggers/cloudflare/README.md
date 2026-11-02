# Cloudflare trigger

GitHub's scheduler starts only a handful of `oracle-a1`'s cron ticks: 3 to 8 runs a day, about 5 on
average, whether the cron says every 15 or every 5 minutes. This Worker takes over with a
Cloudflare Cron Trigger that calls GitHub's workflow-dispatch API every 5 minutes. Background and
measurements: [DECISIONS.md D22](../../docs/DECISIONS.md).

Every tick it:

1. reads the workflow, and does nothing unless its state is `active`. After a success the workflow
   disables itself, so that also stops the trigger;
2. dispatches `oracle-a1.yml` on `main` with `capacity_check=false` and `try_fault_domains=true`.

Why those inputs: `ap-sydney-1` has a single availability domain, so a negative capacity report
skips the only launch. All 199 runs between 2026-09-26 and 2026-11-01 ended that way, without one
launch request. Without the gate and with fault domains, each run makes four launch attempts 20 s
apart (any fault domain, then `FAULT-DOMAIN-1..3`): about 1,150 attempts a day at this cadence.

## Setup

1. **GitHub token.** *Settings → Developer settings → Personal access tokens → Fine-grained
   tokens → Generate new token*: resource owner **MailCoded**, repository access *Only select
   repositories* → `action-jobs`, repository permission **Actions: Read and write**, nothing else.
   If the organization requires approval for fine-grained tokens, approve it under the
   organization's *Settings → Personal access tokens → Pending requests*.
2. **Deploy** with wrangler 4 (`npx wrangler@4 …` works too):

   ```sh
   cd triggers/cloudflare
   wrangler login
   wrangler deploy
   wrangler secret put GITHUB_TOKEN   # paste the token
   ```

   Ticks before the secret exists fail with `GITHUB_TOKEN is not set` and change nothing.
3. **Check.** A new Cron Trigger can take up to 15 minutes to start. Then the *Actions* tab shows
   `oracle-a1` runs with the event `workflow_dispatch` every 5 minutes. In the Cloudflare
   dashboard, *Workers & Pages → oracle-a1-trigger → Logs* shows each tick: the run URL, or why it
   did not dispatch.

## Operating it

- **Pause:** `gh workflow disable oracle-a1.yml` (the trigger then does nothing; GitHub's own
  schedule stops too). Resume with `gh workflow enable oracle-a1.yml`.
- **Change the cadence or the inputs:** edit `triggers.crons` or `vars.INPUTS` in
  `wrangler.jsonc`, then `wrangler deploy`.
- **Token expiry:** an expired or revoked token makes every tick fail with `HTTP 401` in the
  Worker's logs, and no runs appear. Make a new token and run `wrangler secret put GITHUB_TOKEN`.
- **60-day inactivity:** GitHub disables scheduled workflows in public repositories after 60 days
  without repository activity. The trigger then logs `oracle-a1.yml is disabled_inactivity; not
  dispatching.` Re-enable with `gh workflow enable oracle-a1.yml`.
- **After the success:** the workflow is disabled and the trigger stays idle. Remove it with
  `wrangler delete` from this directory, and revoke the token.
- **Tests:** `node --test triggers/cloudflare/test/index.test.mjs` (CI runs them).

## Cost

- Cloudflare: well within Workers Free (5 Cron Triggers per account, 10 ms CPU per invocation; the
  Worker only waits on two requests).
- GitHub: standard runners are free in public repositories. A run takes roughly 2 to 3 minutes
  with four attempts, so 288 runs a day add up to 10 to 14 runner-hours a day. In a private
  repository that would use up the 2,000 free minutes in about two days.
- OCI: a few dozen API calls per run, because each attempt refreshes the network and image data
  before its `LaunchInstance`. A `429` ends the run as `retry (throttled)`.
