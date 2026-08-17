# Security backlog

What's left after the security initiative of August 2026. The assessment
itself — assets, trust boundaries, threat model, and the full detail behind
every finding ID below — is in [`SECURITY.md`](SECURITY.md). This file is just
the queue.

**Status: nothing High or urgent is open.** H-1, H-2, M-2 and L-1 are fixed;
see the summary table in `SECURITY.md` §8 for the authoritative status of
every finding.

---

## Queue

### M-4 · No MFA on the Cognito pool

`infra/modules/auth/main.tf`. `mfa_configuration` is unset, so it defaults to
`OFF` — single-factor auth is now the weakest link protecting the data. Add
`mfa_configuration = "OPTIONAL"` (or `"ON"`; it's a single-user pool) plus
`software_token_mfa_configuration { enabled = true }`, then enrol an
authenticator.

Worth doing at the same time: `user_pool_add_ons` threat protection is
included in the Essentials tier already being paid for and is not enabled.

### L-3 · Delete `debug_allow_any_ref`

`infra/variables.tf` and the ternary in `apply_trust` in
`infra/modules/cicd/main.tf`. Setting it `true` switches the apply role's
trust condition to a repo-wide wildcard, letting any branch assume the role
that can change infrastructure. It is correctly defaulted `false`, and the
OIDC failure it was added to diagnose is long resolved. Remove the variable
and both branches of the conditional.

### M-3 · Plan role holds account-wide `ReadOnlyAccess`

`aws_iam_role_policy_attachment.plan_readonly` in
`infra/modules/cicd/main.tf`, trusted from `repo:<claim>:*` — any branch, any
workflow. `ReadOnlyAccess` is not scoped to Terraform state: it permits
`dynamodb:Scan` on `liftlog-prod` and `cognito-idp:ListUsers`.

Replace with an inline policy granting only what `terraform plan` needs:
`s3:GetObject`/`ListBucket` on the state bucket, plus `Describe*`/`Get*`/
`List*` on the stack's services.

### Small fixes, batchable in one pass

| ID | Where | Fix |
|---|---|---|
| L-4 | `api/index.mjs` `getJwks`/`verifyToken` | Unknown `kid` throws 401 instead of refetching the 1-hour JWKS cache, so Cognito key rotation causes up to an hour of failed sign-ins. Refetch once on miss, guarded against hammering the endpoint. |
| L-5 | `api/index.mjs`, `ALLOWED_SK_PREFIXES` check | `sk === p \|\| sk.startsWith(p)` — `"PROFILE"` has no `#`, so `PROFILE_anything` passes. Require exact match or `p.endsWith("#") && sk.startsWith(p)`. |
| L-8 | `sw.js`, navigation branch | Caches the response with no status check, unlike the asset branch. A 5xx or captive-portal page can overwrite the cached app shell. |
| L-2 | `index.html` `cloudSignIn()` | No OAuth `state` parameter. Currently redundant with PKCE, but only by coincidence of how the redirect handler works. |
| — | `api/index.mjs` `handlePost` | Defence in depth for L-1: `data` is stored as an opaque blob with no schema validation. |

### Deferred by design

**M-1** (public `lambda:InvokeFunction` grant) and **M-5** (unauthenticated
invocations are billed before the 401) both resolve with CloudFront + Origin
Access Control. That arrives with **Phase 5**, the move from Vercel to S3 +
CloudFront hosting. There is no reason to build a distribution solely for
these two.

---

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
it in CI and Dependabot keeps the pins current. Note that `trivy-action` must
use `v`-prefixed tags — the unprefixed ones were removed after a supply chain
attack.

**The CSP includes `script-src 'unsafe-inline'`**, which is unavoidable while
the app is a single file with an inline `<script>`. It therefore does *not*
block injected inline event handlers. Output escaping is the control for that.
Do not describe the CSP as XSS protection.

**Bump both `const BUILD` in `index.html` and `CACHE_VERSION` in `sw.js`** when
shipping client changes, or installed PWAs keep serving the old version.

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
| Checkov baseline | `passed=99 failed=0 skipped=24` — keep `failed` at 0 |

Architecture rationale: [`DECISIONS.md`](DECISIONS.md).
