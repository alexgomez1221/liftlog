# Security backlog

What's left after the security initiative of August 2026. The assessment
itself — assets, trust boundaries, threat model, and the full detail behind
every finding ID below — is in [`SECURITY.md`](SECURITY.md). This file is just
the queue.

**Status: all findings closed except M-1 and M-5 (both deferred to Phase 5)
and L-6 (accepted).** MFA is enrolled and required. See `SECURITY.md` §8 for
authoritative status.

---

## Queue

Nothing actionable outstanding. What follows is reference material for when something goes wrong.

### If you are locked out of Cognito

```bash
cd ~/Apps/FitnessApp/liftlog/infra
export AWS_PROFILE=liftlog-tf
terraform apply -var 'mfa_configuration=OFF'
```

Then **immediately set the default in `infra/variables.tf` to match** and
commit it. A `-var` flag does not persist, so a committed default higher than
the applied state means the next CI apply re-locks you — the same divergence
as H-2.

Note that `OFF` also disables `software_token_mfa_configuration`, which makes
`AssociateSoftwareToken` fail. It gets you back in, but you must return to
`OPTIONAL` before you can enrol again.

Two things that do **not** work, both already tried:

- `admin-set-user-mfa-preference ... Enabled=false` — the challenge follows
  the **association**, not the preference list.
- Reading `UserMFASettingList` to decide whether a user has MFA — it reports
  the preference and stayed `null` throughout, including while the user was
  actively being challenged.

**Never delete and recreate the Cognito user to escape this.** It is the usual
advice online and it would be destructive here: the DynamoDB partition key is
`USER#${sub}`, so a new user means a new `sub` and every workout record
orphaned. Your existing session also survives a lockout — the refresh token is
valid 30 days — so there is time to fix it properly.

### Deferred to Phase 5 · M-1 and M-5

The public Lambda function URL (`lambda:InvokeFunction` granted to `*` without
auth-type scoping) and its unauthenticated invocation cost. Both resolve with
CloudFront + Origin Access Control, which arrives with the move from Vercel to
S3 + CloudFront. There is no reason to build a distribution solely for these.
When Phase 5 lands, remove the `CKV_AWS_301` and `CKV_AWS_258` suppressions in
`infra/modules/api/main.tf`.

### Accepted · L-6

The AWS account ID appears in the state bucket name and the Cognito hosted-UI
domain. Unavoidable — Cognito publishes it to anyone who signs in.

### Optional hardening, not a finding

`handlePost` in `api/index.mjs` stores the `data` blob without schema
validation. Output escaping (L-1) already covers the injection path this would
close; this is belt to that fix's braces, worth doing if the sync payload ever
grows a more complex shape.

## Decisions not to regress

Each of these looks like an oversight and isn't. Changing one reopens a
finding.

**Callback and logout URLs stay committed as defaults** in
`infra/variables.tf`. Reverting them to localhost-only reintroduces H-2: CI
has no access to `terraform.tfvars`, so it applies different values than a
laptop does and silently breaks production sign-in. `terraform.tfvars.example`
warns against overriding them locally for the same reason.

**`reserved_concurrency` stays at `-1`** until the Lambda *Concurrent
executions* quota (`L-B99A9384`) is raised above 10. AWS rejects any
reservation that would drop unreserved concurrency below 10, so on this
account no positive value is accepted. With one function, the account quota is
the cap anyway.

**Checkov owns Terraform. Trivy runs `vuln,secret` only.** Re-enabling Trivy's
`misconfig` scanner produces findings that duplicate documented Checkov
suppressions under a second rule vocabulary — and Trivy does not read
`#checkov:skip` comments, so silencing them means a parallel ignore file that
drifts. One of those findings also contradicted its own rule text.

**Every Checkov suppression is inline, on the resource, with a reason.** Never
add a `skip_check` list to the workflow.

**Actions are pinned to commit SHAs.** `scripts/pin-actions.sh --check` gates
it in CI and Dependabot keeps the pins current. Two things not to change back:
`--check` fails only on UNPINNED entries and merely warns on stale ones —
failing on staleness made every upstream release a red build on main, which is
how a gate gets ignored (`--strict` if you ever want it). And `trivy-action`
must use `v`-prefixed tags; the unprefixed ones were removed after a supply
chain attack.

**Checkov runs via `pip install checkov==3.3.9`, not `checkov-action`.** That
action has had no release since 2022 and only moves `master`. Running the tool
directly drops an unmaintained dependency and keeps the CI and local
invocations identical. Note that `--output-file-path console,<path>` needs a
FILE, not a directory, despite what `--help` says — passing a directory writes
no SARIF and fails silently.

**The CSP includes `script-src 'unsafe-inline'`**, which is unavoidable while
the app is a single file with an inline `<script>`. It therefore does *not*
block injected inline event handlers. Output escaping is the control for that.
Do not describe the CSP as XSS protection.

**Bump both `const BUILD` in `index.html` and `CACHE_VERSION` in `sw.js`** when
shipping client changes, or installed PWAs keep serving the old version.

**Cognito threat protection stays off.** It requires the Plus feature plan —
it is not free — and its compromised-credentials half does not function with
SRP authentication, which is the only flow this client uses. That leaves
adaptive auth alone behind a paid upgrade for a single-user pool.

**The plan role must never regain a DynamoDB read or `cognito-idp:ListUsers`.**
Its policy is built on the distinction that a plan *describes* resources and
never *reads* them, and there is an explicit Deny backing that up. An explicit
Deny cannot be overridden, which is the point — a later widening of the Allows
cannot quietly turn it back into a data-exfiltration credential.

---

## Reference

| Thing | Value |
|---|---|
| Live | `https://liftlog-rust.vercel.app` |
| AWS account | `937485903079`, `us-east-1` |
| Terraform profile | `AWS_PROFILE=liftlog-tf` (MFA via `credential_process`) |
| State bucket | `liftlog-tfstate-937485903079`, access logs in `…-logs` |
| Bootstrap module | `infra/bootstrap` — **separate local state**, apply on its own |
| Cognito pool / client | `us-east-1_TE1RGg5if` / `55s97g354jr3al3jdsk5a0or6g` |
| DynamoDB / Lambda | `liftlog-prod` / `liftlog-prod-api` |
| Checkov baseline | `passed=109 failed=0 skipped=25` — keep `failed` at 0 |

Architecture rationale: [`DECISIONS.md`](DECISIONS.md).
