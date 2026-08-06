# Security initiative — what's left for you

Replaces `SECURITY-WIP.md`. The assessment it was staging toward now lives in
[`SECURITY.md`](SECURITY.md); this file is only the part that needs your
terminal, your MFA and your GitHub settings.

Last updated: 2026-08-06

---

## Status of the three steps

| Step | State |
|---|---|
| 1 — Fix high-priority items | Code done. **Apply not run.** Plan discrepancy still unconfirmed. |
| 2 — Assessment + threat model | Done → [`SECURITY.md`](SECURITY.md) |
| 3 — CI scanning | Done → [`.github/workflows/security.yml`](../.github/workflows/security.yml). Checkov passes locally: 99 passed, 0 failed, 24 documented suppressions. |

---

## 1. Confirm the drift, then apply

Still the first thing to do, and still unconfirmed. The hypothesis in the old
WIP notes holds up on static evidence: `infra/variables.tf` defaulted both
`callback_urls` and `logout_urls` to localhost-only, `terraform.yml` sets
only `TF_VAR_alert_email`, the apply job fires on push to `main` matching
`infra/**`, and `d7edd58` — the last commit on `main` — touched `infra/`.

One detail the old notes missed: `infra/main.tf:45` derives the Lambda
function URL's CORS `allow_origins` from `callback_urls`, so that reverted
too. If sign-in is broken, CORS is likely broken alongside it.

```bash
cd ~/Apps/FitnessApp/liftlog/infra
export AWS_PROFILE=liftlog-tf

# One line per changing resource.
terraform plan -no-color | grep -E '^  # '
```

Directly against AWS, bypassing state:

```bash
aws cognito-idp describe-user-pool-client \
  --user-pool-id us-east-1_TE1RGg5if \
  --client-id 55s97g354jr3al3jdsk5a0or6g \
  --query 'UserPoolClient.CallbackURLs'
```

Only `http://localhost:8080/` coming back confirms it — and means sign-in
from the phone is currently broken. Test it either way.

The fix is already in the working tree: the real Vercel URLs are now the
committed defaults in `variables.tf`, so CI and your laptop produce identical
plans. `terraform.tfvars.example` carries a warning against re-overriding
them locally.

Then:

```bash
terraform plan -out=tfplan   # read it
terraform apply tfplan
```

**Expect more than the two changes you were originally chasing.** This
session also changed the CI role policy, the SNS topic, and added an access
log bucket. See §2.

## 2. Read the plan carefully — the apply role changed

This is the one thing most likely to bite, so it gets its own section.

`infra/modules/cicd/main.tf` no longer grants `iam:*` on `*`. That grant was
admin-equivalent regardless of the Deny list — anything holding it can create
a role trusting itself and attach `AdministratorAccess`. Checkov flags the old
shape under five separate checks. Full reasoning in
[`SECURITY.md` H-1](SECURITY.md).

IAM writes are now scoped to `role/liftlog-*` and `policy/liftlog-*`, with
reads left broad because Terraform refreshes everything on every run.

**This has not been tested against a real apply.** If a later CI run fails
with `AccessDenied` on an `iam:` action, add that action to the
`IamWriteOwnStackOnly` statement. Your local profile is unaffected by this
policy, so recovery is always:

```bash
cd ~/Apps/FitnessApp/liftlog/infra
export AWS_PROFILE=liftlog-tf
terraform apply
```

Also new in this plan, both from the Checkov pass:

- SNS topic gains `kms_master_key_id = "alias/aws/sns"` (free managed key).
- A new `${state_bucket}-logs` bucket in `infra/bootstrap`, receiving S3
  server access logs for the Terraform state bucket. **This is in the
  bootstrap module, which has its own local state** — apply it separately:

  ```bash
  cd ~/Apps/FitnessApp/liftlog/infra/bootstrap
  export AWS_PROFILE=liftlog-tf
  terraform plan
  ```

## 3. Pin the actions

`scripts/pin-actions.sh` had a bug: `changed=1` was set inside a `while read`
loop fed by a pipeline, so it ran in a subshell and never reached the parent.
`--check` therefore printed "All actions pinned." and exited 0 even when it
had just listed unpinned actions — the CI gate it existed to provide was a
no-op. Verified against the original: it found two unpinned actions and still
exited 0.

Rewritten to read via redirect instead of a pipe, and to re-resolve the tag
in the trailing comment so re-running actually updates a moved pin. Tested
against a stubbed resolver across five cases: unpinned, already-current,
stale-pin, no-comment, and unresolvable. `mapfile` is deliberately avoided —
macOS ships bash 3.2 as `/bin/bash`.

It could not be run here: the sandbox has no route to `api.github.com`.

```bash
cd ~/Apps/FitnessApp/liftlog
export GITHUB_TOKEN=$(gh auth token)   # optional, raises the 60/hr limit
./scripts/pin-actions.sh
git diff .github/workflows
```

Both workflows need it — `terraform.yml` and the new `security.yml`. The
`pin-check` job in `security.yml` will fail until you do, which is the point.

## 4. Turn on secret scanning and push protection

GitHub → Settings → Code security. Enable **secret scanning** and **push
protection**. Free on public repos.

Push protection would have blocked both AWS keys exposed in screenshots
before they reached a commit. The gitleaks job in `security.yml` is detection
after the fact; these two are prevention. They are not substitutes.

## 5. Then delete this file

Once §§1–4 are done, this file has no reason to exist. `SECURITY.md` is the
durable document.

---

## What changed on disk this session

| File | Change |
|---|---|
| `infra/variables.tf` | Real callback/logout URLs committed as defaults (H-2) |
| `infra/terraform.tfvars.example` | Warns against re-overriding them locally; `alert_email` documented as the only required value |
| `infra/modules/cicd/main.tf` | `iam:*` split into scoped read/write statements; Deny expanded (H-1) |
| `infra/modules/observability/main.tf` | SNS topic encrypted with `alias/aws/sns` |
| `infra/bootstrap/main.tf` | Access-log bucket + logging on the state bucket; multipart-abort rule |
| `infra/modules/api/main.tf` | Checkov suppressions with rationale (DLQ, VPC, env-var KMS, code signing, X-Ray, public URL) |
| `infra/modules/data/main.tf` | `CKV_AWS_119` suppression for the AWS-owned key decision |
| `scripts/pin-actions.sh` | Subshell bug fixed; stale-pin detection added |
| `.github/workflows/security.yml` | New — Checkov, Trivy, gitleaks, CodeQL, pin-check |
| `.github/dependabot.yml` | New — weekly grouped bumps of the pinned action SHAs |
| `.github/workflows/terraform.yml` | Actions pinned; plan job skipped for Dependabot PRs (no OIDC token) |
| `docs/SECURITY.md` | New — assessment and threat model |
| `docs/SECURITY-WIP.md` | Deleted, replaced by this file |

Nothing is committed. `git status` will show all of it.

## Findings not yet addressed

Full detail in [`SECURITY.md`](SECURITY.md) §6. Nothing High remains open.
In the order worth doing them:

1. **Secret scanning + push protection** (§4 above) — two checkboxes.
2. **M-2, no CSP or security headers.** A single `headers` block in
   `vercel.json`. The refresh token sits in `localStorage` for 30 days, so
   script execution on the origin is a 30-day account takeover; a CSP is what
   bounds that. Ready-to-paste block is in the finding.
3. **M-4, no MFA on the Cognito pool.** `mfa_configuration` is unset, so it
   defaults to `OFF`. Two lines of Terraform plus enrolling an authenticator.
4. **M-3, plan role holds account-wide `ReadOnlyAccess`** and trusts any ref
   in the repo. That reads every DynamoDB item and the Cognito user list, not
   just Terraform state.
5. **L-1, unescaped entity IDs in HTML attributes.** `esc()` is used
   correctly on display strings but not on `${w.id}` and friends, and those
   IDs round-trip through the sync API. Self-XSS, so low on its own — but it
   is the ingredient M-2 needs to become an account takeover.
6. **L-3, delete `debug_allow_any_ref`.** The OIDC failure it was added to
   diagnose is resolved. It is one variable away from letting any branch
   assume the apply role.
7. L-2 (no OAuth `state`), L-4 (JWKS not refetched on unknown `kid`), L-5
   (`sk` prefix match), L-8 (service worker caches error responses).
