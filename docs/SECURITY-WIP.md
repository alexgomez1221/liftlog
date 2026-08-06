# Security initiative — work in progress

Handoff notes. Delete this file once the three steps below are done and the
findings have moved into `docs/SECURITY.md`.

Last updated: 2026-08-05

---

## The plan, in three steps

1. **Fix high-priority items** — in progress, blocked (see below)
2. **Write the assessment + threat model** — not started
3. **Automate scanning in CI** — not started

---

## Step 1 — where it stands

### Done: edits on disk, not yet committed, not yet applied

`git status` should show six modified files under `infra/` plus an untracked
`scripts/` directory.

| File | Change |
|---|---|
| `modules/auth/main.tf` | `allow_admin_create_user_only = !var.allow_signup` |
| `modules/auth/variables.tf` | `variable "allow_signup"`, bool, default `false` |
| `modules/api/main.tf` | `reserved_concurrent_executions = var.reserved_concurrency` |
| `modules/api/variables.tf` | `variable "reserved_concurrency"`, number, default `5` |
| `main.tf` | both wired into their modules |
| `variables.tf` | both root variables added |
| `scripts/pin-actions.sh` | new, executable, syntax-checked, **not yet run** |

Closing self-signup does **not** affect the existing account — only new
registration. The hosted UI's "Sign up" link stops working, which is intended.

The concurrency cap bounds *rate*, not total volume. Five concurrent
executions is still roughly 50 req/s. The $5 budget alarm is the real cost
backstop; genuine rate limiting would mean CloudFront + WAF.

### Blocked on: an unexplained plan diff

`terraform plan` reported **7 changes**. The two edits above account for 2.
The other 5 are unidentified.

**Leading hypothesis — unconfirmed.** `terraform.tfvars` is gitignored, and
`.github/workflows/terraform.yml` only sets `TF_VAR_alert_email`. It never
sets `callback_urls` or `logout_urls`. So the apply job that ran on merge to
main used the defaults in `variables.tf`:

```hcl
default = ["http://localhost:8080/"]
```

That would have rewritten the Cognito client's callback URLs and the Lambda
function URL's CORS origins to localhost-only, and a local plan reading the
real tfvars now wants to put them back.

**If true, sign-in from the phone is currently broken.** Test it.

### To confirm, first thing next session

```bash
cd ~/Apps/FitnessApp/liftlog/infra
export AWS_PROFILE=liftlog-tf
terraform plan -no-color | grep -E '^  # '
```

One line per changing resource. And directly against AWS, bypassing state:

```bash
aws cognito-idp describe-user-pool-client \
  --user-pool-id us-east-1_TE1RGg5if \
  --client-id 55s97g354jr3al3jdsk5a0or6g \
  --query 'UserPoolClient.CallbackURLs'
```

Only `http://localhost:8080/` returned confirms it.

### The fix, if confirmed

A variable whose real value lives only in a gitignored file, with a default
that silently works, is the actual defect — CI applied a valid-looking plan
that quietly degraded production.

Preferred fix: **commit the real callback/logout URLs as the defaults.** They
are public identifiers, not secrets, and it makes CI and the laptop produce
identical plans. The alternative — removing the defaults so an unset variable
fails loudly — also works but leaves CI needing the values injected anyway.

This belongs in the assessment as a finding: *deployment pipeline can silently
revert security-relevant configuration.*

### Still to do in step 1

- [ ] Resolve the plan discrepancy, then `terraform apply`
- [ ] Run `./scripts/pin-actions.sh`, review `git diff .github/workflows`, commit
- [ ] GitHub → Settings → Code security: enable **secret scanning** and
      **push protection**. Push protection would have blocked both AWS keys
      exposed in screenshots before they reached a commit. Free on public repos.

---

## Step 2 — assessment + threat model

Not started. Target: `docs/SECURITY.md` covering assets, trust boundaries,
attack surface, and findings with severity and remediation.

**There is a `security-review` skill available** — worth invoking against the
working diff before writing the document by hand.

Known material to fold in:

- Authorization model: `PK = USER#${sub}` is taken from the verified token, and
  a client-supplied `PK` is ignored. This is the single line the whole
  multi-tenant isolation story rests on (`api/index.mjs`).
- JWT verification: RS256 via JWKS, alg allowlist to block `none`/HS256
  confusion, claims checked (`iss`, `client_id`, `token_use`, `exp`, `nbf`).
- `lambda:InvokeFunction` is granted to `*` and is not scoped by auth type —
  broader than the URL grant. Exposure is bounded because the handler rejects
  anything without a valid JWT, but it's a real finding. CloudFront + OAC is
  the remediation.
- Function URL is `authorization_type = "NONE"`; unauthenticated requests still
  invoke the function before the handler returns 401, so it's an
  invocation-cost surface as well as a data surface.
- IAM: least-privilege Lambda role (2 DynamoDB actions on 1 table ARN),
  confused-deputy `aws:SourceAccount` guard, split plan/apply CI roles.
- Two AWS access keys were exposed in screenshots and rotated
  (`AKIA5URUDUTT4M5MKND7`, `AKIA5URUDUTTRW6PQOUR`). Both are dead; worth an
  entry as a process finding.
- Repo audited clean: no tfstate/tfvars tracked, no key material in history.
- Client-side: `localStorage` is origin-scoped and unencrypted — anything with
  script execution on the origin reads it. Accepted risk for a personal app.
- Sync is not backup. Deletions replicate.

---

## Step 3 — CI scanning

Not started. Intended tools:

| Tool | Target |
|---|---|
| Checkov or tfsec | Terraform misconfiguration |
| Trivy | filesystem / dependency scan |
| gitleaks | secrets in history and on push |
| CodeQL | JavaScript in `index.html` and `api/` |
| `pin-actions.sh --check` | fail the build on unpinned actions |

Expect Checkov to flag the DynamoDB table for using an AWS-owned key rather
than a CMK. That is a deliberate decision (a CMK costs $1/month for no
meaningful gain here) — suppress it with a comment explaining why, rather than
either "fixing" it or ignoring the finding.

---

## Reference

| Thing | Value |
|---|---|
| Repo | `~/Apps/FitnessApp/liftlog` → `github.com/alexgomez1221/liftlog` |
| Live | `https://liftlog-rust.vercel.app` |
| AWS account | `937485903079`, `us-east-1` |
| Terraform profile | `AWS_PROFILE=liftlog-tf` (MFA via `credential_process`) |
| State bucket | `liftlog-tfstate-937485903079` |
| Cognito pool | `us-east-1_TE1RGg5if` |
| Cognito client | `55s97g354jr3al3jdsk5a0or6g` |
| DynamoDB table | `liftlog-prod` |
| Lambda | `liftlog-prod-api` |
| App build | 8 (`const BUILD = 8` in `index.html`, `liftlog-v8` in `sw.js`) |

Deferred by choice, unrelated to security: **Phase 5**, moving hosting from
Vercel to S3 + CloudFront. Note that it would also deliver the CloudFront
distribution that steps 2 and 3 keep pointing at as the remediation for the
function URL exposure.

Background and rationale for existing decisions: `docs/DECISIONS.md`.
