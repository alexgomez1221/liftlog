# Lift Log

Personal workout tracker. Offline-first PWA, single user, optional cloud sync.
Public repo: `github.com/alexgomez1221/liftlog` · Live:
`https://liftlog-rust.vercel.app`

```
Browser (PWA on Vercel)  →  Cognito hosted UI (OAuth code + PKCE, TOTP MFA)
                         →  Lambda function URL (verifies JWT via JWKS)
                         →  DynamoDB single table, PK = USER#<sub>
```

`localStorage` is the source of truth; the cloud is a replica. Sync is
last-write-wins on `updatedAt`. Nothing on the network path may block the UI —
the app has to work in a gym basement with no signal.

## Layout

| Path | What |
|---|---|
| `index.html` | The entire app — one file, one inline `<script>`, one `<style>` |
| `api/index.mjs` | Lambda sync handler. **Zero npm dependencies**, deliberately |
| `sw.js` | Service worker |
| `infra/` | Terraform. Modules: `auth`, `api`, `data`, `cicd`, `observability` |
| `infra/bootstrap/` | State bucket + budget. **Separate local state**, applied on its own |
| `scripts/pin-actions.sh` | Pins GitHub Actions to commit SHAs |
| `docs/` | `SECURITY.md`, `SECURITY-NEXT.md`, `DECISIONS.md`, `DEPLOY-VERCEL.md` |
| `infra/PHASE*.md` | Build history, kept as narrative. Not current-state docs |

## Rules

**Bump `const BUILD` in `index.html` AND `CACHE_VERSION` in `sw.js`** on every
client change, or installed PWAs keep serving the old version.

**Escape everything interpolated into HTML.** `esc()` exists and is used. IDs
and entity fields round-trip through the sync API, so they are not trustworthy
just because the client generated them. The CSP carries `'unsafe-inline'` and
therefore does **not** stop injected inline handlers — escaping is the control.

**Keep `api/index.mjs` dependency-free.** The AWS SDK v3 ships with the
`nodejs20.x` runtime, so Terraform zips the directory with no build step. A
`package.json` would change the deploy path.

**Never widen the DynamoDB key.** `PK = USER#${sub}` from the *verified* token
is the whole multi-tenant isolation story. A client-supplied `PK` is ignored.
Recreating the Cognito user would change `sub` and orphan every record.

**Terraform defaults must match what is applied.** A value that lives only in
gitignored `terraform.tfvars` or a `-var` flag means CI plans differently than
a laptop, and CI silently wins. That caused a production sign-in outage — see
H-2 in `docs/SECURITY.md`.

**Checkov suppressions go inline on the resource with a written reason.** Never
a `skip_check` list in the workflow. Baseline: `109 passed, 0 failed`.

**Read `docs/SECURITY-NEXT.md` before changing anything security-adjacent** —
it lists decisions that look like oversights and are not.

## Commands

Terraform is Alex's to run (MFA-gated profile):

```bash
cd infra && export AWS_PROFILE=liftlog-tf
terraform plan -out=tfplan && terraform apply tfplan
```

Verify a client change parses (single file, so extract the script first):

```bash
python3 -c "
import re;s=open('index.html').read()
open('/tmp/app.js','w').write(re.search(r'<script[^>]*>(.*)</script>',s,re.S).group(1))"
node --check /tmp/app.js
```

Terraform lint — `terraform validate` needs the binary; Checkov also reports
parse errors and is pip-installable:

```bash
checkov -d infra --framework terraform --compact
```

Deploy is automatic: push to `main` → Vercel for the app, GitHub Actions apply
for infra.

## Style

Concise and direct. Alex is technically strong — skip explanations of what
Terraform or a CSP is. When something is untested, say so and give the recovery
path. Comments in this codebase explain *why*, especially where a decision
looks wrong at first glance; match that.
