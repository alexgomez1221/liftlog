# Security assessment and threat model

Lift Log — personal workout tracker. Single-user, offline-first PWA with
optional cloud sync.

| | |
|---|---|
| Assessed | 2026-08-05, remediation through 2026-08-06 |
| Revision | `main` @ `1599df8` plus the M-2 / L-1 remediation |
| Method | Manual review of application, infrastructure and pipeline source, plus Checkov 3.3.9 against `infra/` |
| Reviewed | `api/index.mjs`, `infra/**/*.tf`, `index.html` (cloud sync layer), `sw.js`, `vercel.json`, `.github/workflows/terraform.yml` |

Not covered: no dynamic testing, no dependency audit (there are no runtime
npm dependencies), no review of the Vercel account or GitHub org
configuration itself, no review of `infra/bootstrap`.

---

## 1. System overview

```
  Browser (PWA, Vercel)
    │  localStorage = source of truth
    │
    ├──> Cognito hosted UI ──────────> Cognito user pool
    │    OAuth 2.0 code + PKCE          issues RS256 JWTs
    │
    └──> Lambda function URL ────────> Lambda (nodejs20.x)
         Bearer <access_token>          verifies JWT via JWKS
                                        │
                                        └──> DynamoDB (single table)
                                             PK = USER#<sub>
```

The app is offline-first: `localStorage` holds the authoritative copy and the
cloud is a replica. Sync is last-write-wins on `updatedAt`. Everything on the
network path is best-effort and never blocks the UI.

## 2. Assets

Ranked by what their loss would actually cost.

| Asset | Where it lives | Concern |
|---|---|---|
| Workout history and body metrics | `localStorage`, DynamoDB `liftlog-prod` | Confidentiality, integrity, availability. Body-weight and training data is personal but not regulated. |
| Cognito refresh token (30 d) | `localStorage` | Full account access for its lifetime. The highest-value item on the client. |
| Cognito access token (1 h) | `localStorage` | Bounded API access. |
| AWS account `937485903079` | — | The real prize. Compromise here dwarfs the workout data. |
| Terraform state | `s3://liftlog-tfstate-937485903079` | Contains resource identifiers and can be used to hijack managed resources. |
| CI apply role | IAM | Path to the AWS account. See H-1. |
| App integrity (what ships to the phone) | Vercel, GitHub | Serving modified JS reaches every asset above. |

## 3. Trust boundaries

1. **Browser → Cognito.** Public client, no secret, PKCE. The browser is
   untrusted; PKCE is what makes a public client safe.
2. **Browser → Lambda function URL.** The internet reaches this endpoint
   directly. The JWT is the only gate. Everything before `verifyToken` in the
   handler is attacker-reachable.
3. **Lambda → DynamoDB.** Crossed with an IAM role scoped to two actions on
   one table ARN.
4. **Per-user isolation inside DynamoDB.** Not an infrastructure boundary at
   all — it is one line of application code (§5, "What holds up").
5. **GitHub → AWS.** OIDC federation. A workflow run is a principal in the
   AWS account.
6. **Developer laptop → AWS.** `AWS_PROFILE=liftlog-tf`, MFA via
   `credential_process`.

Boundaries 5 and 6 are the ones where a mistake costs the most, and boundary 5
is the one where a mistake is easiest to make quietly.

## 4. Threat model

| Actor | Capability | Motivation | Realistic? |
|---|---|---|---|
| Opportunistic internet scanner | Finds the Lambda URL, sends unauthenticated traffic | Cost, noise, opportunistic exploitation | Yes — continuous |
| Authenticated pool member | Holds a valid JWT for their own `sub` | Read or write another user's data | Only if self-signup is open — now closed via `allow_signup = false` |
| Attacker with script execution on the app origin | Reads `localStorage` | Account takeover via the refresh token | Requires an injection vector — see M-2, L-1 |
| Attacker with GitHub write access | Opens a PR or pushes to `main` | Reach the AWS account | Repo is single-maintainer; blast radius is large (H-1, M-3) |
| Attacker with the AWS apply role | Assumed via a compromised workflow | Full account | Follows from H-1 |
| Passive credential harvester | Scrapes public repos, screenshots, pastes | Long-lived AWS keys | Already happened once — L-7 |

Explicitly out of scope: a targeted attacker with physical access to an
unlocked phone, and nation-state adversaries. Neither is a sensible threat
model for a personal lifting log.

## 5. What holds up

Recording this matters as much as the findings — these are the decisions that
are doing the actual work, and they should not be regressed.

**Per-user isolation.** `api/index.mjs` derives `PK` from `USER#${sub}` where
`sub` comes from the verified token, on both the read and the write path. A
client-supplied `PK` is never read. This single decision is the entire
multi-tenant isolation story, and it is implemented correctly.

**JWT verification.** RS256 pinned by allowlist rather than trusting
`header.alg`, which closes both the `none` bypass and the RS256→HS256
confusion attack. `kid` is required and looked up in the pool's JWKS.
Signature is verified before any claim is read. Claims checked: `exp`, `nbf`,
`iss`, `token_use === "access"`, `client_id`, and presence of `sub`. Checking
`token_use` is a step many implementations skip, and skipping it lets an ID
token be replayed as an access token.

**Fail-closed ordering.** Authentication runs before routing in the handler,
so an unknown path cannot reach a code path that skips auth.

**IAM for the Lambda.** Two DynamoDB actions on one table ARN, logs scoped to
its own log group, and a deliberate avoidance of
`AWSLambdaBasicExecutionRole` (which would grant `logs:*` account-wide). A
confused-deputy `aws:SourceAccount` condition on the trust policy.

**No long-lived AWS credentials in CI.** OIDC with the numeric-ID form of the
`sub` claim, which survives neither a user rename nor a repo rename — stricter
than the string form most tutorials show.

**Cognito client hygiene.** No client secret, PKCE, SRP-only auth flows
(no `USER_PASSWORD_AUTH`), `prevent_user_existence_errors` enabled,
token revocation enabled, 1-hour access tokens.

**Data durability.** Point-in-time recovery, deletion protection, and a
Terraform `prevent_destroy` lifecycle guard on the table.

**Output escaping exists and is used.** `esc()` is applied to user-entered
names and free text throughout the render path. L-1 is about the gaps, not an
absence.

---

## 6. Findings

Severity is calibrated to *this* application — a single-user personal project
on a personal AWS account — not to an enterprise baseline. Where that
calibration changes the rating, it is stated.

### H-1 · CI apply role was effectively account administrator

**`infra/modules/cicd/main.tf`** — escalation path fixed, residual breadth accepted

The apply role's policy was described as "scoped to the services this stack
actually uses rather than AdministratorAccess". It included `iam:*` on `*`.

`iam:*` is not a service scope — it is a privilege-escalation primitive. A
principal holding it can `iam:CreateRole` with a trust policy naming itself,
attach `AdministratorAccess`, and assume it; or attach an admin policy
directly to the role it is already using; or create a new policy version on
any existing policy. The `DenyAccountDestruction` statement blocks
`organizations:*`, `account:CloseAccount`,
`iam:DeleteAccountPasswordPolicy` and `s3:DeleteBucket` — none of which are on
that path. The deny list constrains destruction, not escalation.

Combined with `lambda:*` and `iam:PassRole` (implied by `iam:*`), the same
holds via Lambda: create a function with an admin role attached and invoke it.

This is the highest-consequence finding in the codebase. Anything that
compromises a workflow run on `main` — a malicious dependency in an action, a
supply-chain attack on `actions/checkout`, a pushed commit — yields the AWS
account, not just this stack.

Checkov flags the original shape under five independent checks —
`CKV_AWS_107` (credentials exposure), `CKV_AWS_108` (data exfiltration),
`CKV_AWS_109` (unconstrained permissions management), `CKV_AWS_110`
(privilege escalation) and `CKV2_AWS_40` (full IAM privileges) — which is
useful corroboration that this is a recognised anti-pattern and not a
judgement call.

**Remediation applied.** `iam:*` is gone. The policy now has four statements:

| Statement | Grant |
|---|---|
| `ManageStackServices` | the eight non-IAM services, on `*` |
| `IamRead` | `iam:Get*`, `List*`, `Simulate*`, `CreateServiceLinkedRole` on `*` — needed because Terraform refreshes every managed resource on each run, and these actions largely do not support resource-level permissions |
| `IamWriteOwnStackOnly` | IAM mutations including `PassRole`, restricted to `role/liftlog-*` and `policy/liftlog-*` |
| `IamManageGithubOidcProvider` | OIDC provider actions, pinned to the exact provider ARN |
| `DenyAccountDestructionAndIdentityCreation` | expanded Deny: user creation, access keys, login profiles, SAML providers, permissions-boundary deletion |

Scoping to `liftlog-*` is clean because every resource in the stack is named
from `local.name` (`liftlog-prod`, `liftlog-prod-api`) or `var.project`
(`liftlog-gha-plan`, `liftlog-gha-apply`). `iam:PassRole` is scoped rather
than left in the read statement — unscoped `PassRole` is itself a standard
escalation path, and dropping it into the wrong statement would have
reintroduced the finding in a less obvious form.

`CKV2_AWS_40` now passes.

**Residual breadth — accepted, with a condition.** The remaining five checks
still fire on `ManageStackServices`: `s3:*`, `dynamodb:*`, `lambda:*` and
friends are granted on `*`, so the apply role can act on any bucket, table or
function in the account. They are suppressed inline with that reasoning.

This is accepted because the account hosts exactly one stack, which makes
"any resource in the account" and "this stack's resources" the same set
today. That is a property of the account, not of the policy. **If this
account ever hosts anything besides Lift Log, remove those suppressions and
scope each service to its `liftlog-*` ARNs.** Scoping now would mean
enumerating ARNs across eight services, several of which
(`cognito-idp:CreateUserPool`, `budgets:*`) do not support resource-level
permissions on their create actions at all.

**Not yet done:** an IAM permissions boundary requiring that any role CI
creates carries it. That would close escalation even within the `liftlog-*`
prefix, and is the natural next step if the threat model tightens.

**Untested.** This change has not been validated against a real apply. If CI
fails with `AccessDenied` on an IAM action, the missing action needs adding
to `IamWriteOwnStackOnly`; recovery is a local `terraform apply` with
`AWS_PROFILE=liftlog-tf`, which is unaffected by this policy.

### H-2 · Deployment pipeline could silently revert security-relevant configuration

**`infra/variables.tf:19-33`, `.github/workflows/terraform.yml:36` — fixed in this change**

`callback_urls` and `logout_urls` defaulted to `["http://localhost:8080/"]`.
The real values lived only in `infra/terraform.tfvars`, which is gitignored.
The workflow sets `TF_VAR_alert_email` and nothing else.

CI therefore planned and applied with different inputs than any local run. The
apply job that ran on the merge of `d7edd58` to `main` would have rewritten the
Cognito client's callback URLs — and, through
`infra/main.tf:45`, the Lambda function URL's CORS `allow_origins` — to
localhost only. Both changes look valid in a plan. Neither is obviously wrong
in a diff. The result is a production sign-in outage introduced by a green CI
run.

The class of defect is what matters: **a variable whose real value exists only
outside version control, with a default that silently works, guarantees that
CI and local runs diverge.** It fails silently by construction, and it can
degrade a security control (redirect allowlists are a security control —
they are what stops an authorization code being redirected to an
attacker-controlled origin) as easily as an operational one.

**Remediation (applied):** the real callback and logout URLs are now committed
as the variable defaults. They are public identifiers, visible in every
redirect and in any browser's network tab, so committing them discloses
nothing. `terraform.tfvars.example` now carries an explicit warning against
re-overriding them locally.

The rejected alternative — removing the defaults so an unset variable fails
loudly — is also correct in principle, but leaves CI needing the values
injected as repository variables, which reintroduces two sources of truth.

**Residual:** no mechanism prevents the next variable from repeating this.
Consider a CI step asserting that `terraform plan` on `main` is empty
immediately after an apply.

### M-1 · `lambda:InvokeFunction` granted to `*` without auth-type scoping

**`infra/modules/api/main.tf:166-171`**

The second permission grants `lambda:InvokeFunction` to principal `*` with no
`function_url_auth_type` and no `source_arn`. Unlike the
`lambda:InvokeFunctionUrl` grant above it, this is not scoped to the function
URL — any AWS principal, in any account, can call the Lambda API directly.

A direct invoke supplies the event payload verbatim, bypassing the function
URL's CORS configuration and its HTTP shape entirely. The handler holds up:
`method` and `path` default to `GET` and `/`, and `bearerToken()` throws 401
on a missing `authorization` header, so an empty event is rejected. Data
exposure is nil.

What remains is cost and noise: every direct invoke is a billed invocation
that also consumes the 5-execution concurrency reservation, so a sustained
direct-invoke flood is a denial-of-service against sync for the legitimate
user, not merely a bill.

**Remediation:** CloudFront with Origin Access Control in front of the
function URL, then scope both permissions to the distribution. This is already
planned as Phase 5 (S3 + CloudFront hosting), which makes Phase 5 a security
deliverable rather than purely a hosting change. Until then, the $5 budget
alarm is the backstop.

### M-2 · No Content-Security-Policy or security headers on the served app

**`vercel.json`**

`vercel.json` sets cache and content-type headers only. The application is
served with no `Content-Security-Policy`, no `X-Content-Type-Options`, no
`Referrer-Policy`, and no framing restriction.

This matters more here than it would in most apps because the Cognito refresh
token sits in `localStorage` with a 30-day lifetime. Any script execution on
`liftlog-rust.vercel.app` yields a 30-day account takeover, and `localStorage`
offers no defence — it is origin-scoped, unencrypted, and readable by any
script on the origin.

**Fixed.** `vercel.json` now sets a policy on `/(.*)`, plus
`X-Content-Type-Options`, `Referrer-Policy: no-referrer`, a
`Permissions-Policy` denying unused features, and
`Cross-Origin-Opener-Policy`. The app references exactly two external origins
and loads nothing from a CDN, so `connect-src` names literal hosts rather than
wildcards.

**Be clear about what this does and does not buy.** The app is a single HTML
file with one inline `<script>`, so `script-src` needs `'unsafe-inline'`.
That allowance also permits inline event handlers — which means **this CSP
does not block the L-1 injection vector**. An injected `onmouseover=` would
still execute. The control for L-1 is output escaping, which is why L-1 was
fixed in the same change rather than treated as covered by this one.

What the policy does buy:

- `connect-src` bounds where a successful injection can exfiltrate to: your
  own origin, Cognito, and the Lambda URL. Stolen tokens cannot be POSTed to
  an attacker's collector.
- `base-uri 'none'` and `object-src 'none'` close two standard routes for
  escalating a minor injection into script execution.
- `frame-ancestors 'none'` prevents clickjacking.
- `Referrer-Policy: no-referrer` stops the OAuth `?code=` in the landing URL
  leaking via the `Referer` header on any request that fires before
  `history.replaceState` strips it.

The upgrade path is a hashed or nonced `script-src`, which would remove
`'unsafe-inline'` and make the policy a genuine XSS control. A nonce needs
per-request server rendering, which static Vercel hosting cannot do; a
`sha256-` hash is static but must be regenerated on every edit to
`index.html`, so it needs a build step to be safe. Neither is worth it until
the single-file property is given up for another reason.

For reference, the shape that was applied:

```jsonc
{
  "source": "/(.*)",
  "headers": [
    { "key": "Content-Security-Policy",
      "value": "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self' https://*.amazoncognito.com https://*.lambda-url.us-east-1.on.aws; frame-ancestors 'none'; base-uri 'none'; object-src 'none'; form-action 'self'" },
    { "key": "X-Content-Type-Options", "value": "nosniff" },
    { "key": "Referrer-Policy", "value": "no-referrer" }
  ]
}
```

`base-uri 'none'` and `object-src 'none'` are worth having even alongside
`'unsafe-inline'` — both close standard escalation routes from a minor
injection. `connect-src` bounds where a successful injection can exfiltrate
to. `Referrer-Policy: no-referrer` also stops the OAuth `?code=` in the
landing URL leaking via the `Referer` header on any request that fires before
`history.replaceState` strips it.

### M-3 · Plan role holds account-wide `ReadOnlyAccess`, assumable from any ref

**`infra/modules/cicd/main.tf:101-118`**

The plan role attaches the AWS-managed `ReadOnlyAccess` policy and trusts
`repo:<claim>:*` — any branch, any workflow, any event type in the repository.

The inline comment reasons that "the worst a branch or workflow in this repo
can do with it is read state it could already read." That understates the
grant. `ReadOnlyAccess` is account-wide: it permits `dynamodb:Scan` on
`liftlog-prod` (every workout record for every user), `cognito-idp:ListUsers`
(the user roster), `s3:GetObject` across the account, and `ssm:GetParameters`.
It is not scoped to Terraform state.

The attack path: the `pull_request` trigger includes
`.github/workflows/terraform.yml` in its `paths` filter, and for
`pull_request` events GitHub runs the workflow file *from the PR head*. A PR
that edits the workflow to add a `dynamodb scan | curl` step runs with the
plan role's credentials.

Mitigating factors, which are why this is Medium and not High: GitHub does not
issue an OIDC token to workflows triggered by pull requests **from forks**, so
this requires push access to a branch in the repository, and the repo has one
maintainer.

**Remediation:** replace `ReadOnlyAccess` with an inline policy granting only
what `terraform plan` needs — `s3:GetObject`/`ListBucket` on the state bucket,
plus `Describe*`/`Get*`/`List*` on the six services in the stack. Consider
`pull_request_target` or a `workflow_run` split if the repo ever gains
contributors.

### M-4 · No MFA on the Cognito pool; 30-day refresh token on the client

**`infra/modules/auth/main.tf:13-73`, `index.html:2470-2482`**

`mfa_configuration` is unset, so it defaults to `OFF`. `user_pool_add_ons`
(threat protection / compromised-credential detection) is likewise not
configured, despite the pool running on the Essentials tier that includes it.

Single-factor authentication with a 12-character password is the whole gate on
the account. The refresh token is valid 30 days and stored in `localStorage`,
so a credential compromise or a token theft both persist well past the
1-hour access token window that the design comments rely on.

**Remediation:** set `mfa_configuration = "OPTIONAL"` with
`software_token_mfa_configuration { enabled = true }` and enrol. For a
single-user pool, `"ON"` is also viable and strictly better. Separately,
consider enabling threat protection — it is included in the tier already
being paid for.

### M-5 · Function URL is unauthenticated at the edge

**`infra/modules/api/main.tf:174-195`**

`authorization_type = "NONE"` is the correct choice — `AWS_IAM` would require
the browser to hold AWS credentials and sign with SigV4, which a public SPA
cannot do. The consequence is that rejection happens in application code, not
at the edge: every unauthenticated request is a billed Lambda invocation that
holds a concurrency slot for the duration of a JWT parse.

`reserved_concurrent_executions` was intended to bound the *rate* — roughly
50 req/s at this handler's latency — rather than the total. It is a cost
brake, not rate limiting.

**It is not currently set.** AWS rejects any reservation that would drop the
account's unreserved concurrency below 10, and this account's total Lambda
concurrency quota is 10, so no positive value is accepted:

```
InvalidParameterValueException: Specified ReservedConcurrentExecutions for
function decreases account's UnreservedConcurrentExecution below its minimum
value of [10]
```

The variable therefore defaults to `-1`. The practical effect is smaller than
it appears: with one function in the account, the account-wide quota of 10 is
itself the cap, and a flood is bounded at 10 concurrent executions either
way. What the reservation would add is isolation — a guarantee that a runaway
function cannot starve a second one — which has no second function to
protect yet.

**Remediation:** raise the Lambda `Concurrent executions` quota (L-B99A9384)
to 100 or more via Service Quotas, then set `reserved_concurrency = 5`. Do
this before adding a second Lambda, not after. The longer-term answer is the
same as M-1 — CloudFront with WAF and a rate-based rule — which is not
justified at current scale; the $5 budget alarm remains the control that
actually fires.

### L-1 · Entity IDs interpolated into HTML attributes without escaping

**`index.html:1361, 1416, 1425, 1432, 1574, 1660`**

`esc()` is applied consistently to display strings, but entity identifiers go
in raw:

```js
`<div class="hist-item" data-w="${w.id}">`
`<div class="ex-row" data-id="${e.id}">`
`<button class="iconbtn" data-rmenu="${r.id}">`
```

IDs are generated client-side, so under normal use they are safe. They are
not, however, *only* client-generated: they round-trip through the sync API,
and `handlePost` validates `sk`, `updatedAt` and the item shape but stores
`data` as an opaque blob with no schema validation. A crafted `POST /sync`
carrying an `id` of `" onmouseover="…` yields stored XSS that fires on the
next render.

This is self-XSS: the API only permits writes to the caller's own partition,
so the attacker must already hold the victim's token. That caps severity at
Low. It is worth fixing anyway, because it is the ingredient M-2 needs to
become an account takeover, and because "attacker already has a token" is
exactly the position a stolen 30-day refresh token puts them in.

**Fixed.** Ten interpolations now pass through `esc()`. Auditing the fix
turned up one site the original finding missed: `class="setbtn ${s.type}"`
(line 1013). Set type is not an id, but it comes off the wire the same way —
the sync import at line 896 does `type: s.type || 'normal'` with no allowlist,
despite `SET_TYPES` being a fixed four-key map. Two `value=` attributes
carrying user-entered numbers (`reps`, body weight) were escaped for the same
reason: nothing guarantees they are still numbers after a round trip through
an opaque `data` blob.

Deliberately *not* escaped: interpolations of `MUSCLES`, `EQUIPMENT`, `GOALS`,
`SET_TYPES` and loop indices, which are module constants with no path from the
network. `ssColor` was checked and is a lookup into the `SS_COLORS` constant,
so it is safe despite appearing in a `style` attribute.

`const BUILD` and the service worker `CACHE_VERSION` were bumped to 9 so
installed PWAs actually pick the fix up.

**Still open, as defence in depth:** `handlePost` stores `data` as an opaque
blob with no schema validation (`api/index.mjs:215`). Server-side shape
validation would mean a malformed record could not be stored at all, rather
than being stored and then escaped on the way out. Not required now that
output escaping is correct, but it is the belt to this fix's braces.

### L-2 · OAuth authorize request omits the `state` parameter

**`index.html:2448-2461`**

`cloudSignIn()` sends `client_id`, `response_type`, `scope`, `redirect_uri`,
`code_challenge` and `code_challenge_method` — no `state`. `state` is the
standard CSRF defence for the redirect leg.

In this specific implementation PKCE happens to cover the login-CSRF case: an
attacker feeding the victim `?code=<attacker's code>` needs the exchange to
succeed, and `handleAuthRedirect` uses the verifier from the victim's own
`sessionStorage`, which will not match. If the victim never started a flow
there is no verifier at all and the function returns early.

So this is defence that is currently redundant rather than a live hole — but
it is redundant by coincidence of the PKCE implementation, not by design, and
the next refactor of the redirect handler could remove the coincidence.

**Remediation:** generate a random `state` alongside the verifier, store both
in `sessionStorage`, and compare on return before exchanging.

### L-3 · `debug_allow_any_ref` escape hatch remains in the codebase

**`infra/variables.tf:65-69`, `infra/modules/cicd/main.tf:148-156`**

Setting this to `true` switches the apply role's trust condition from
`StringEquals` on `refs/heads/main` to `StringLike` on `repo:<claim>:*` — any
branch, any PR, may then assume the role that H-1 shows is account
administrator.

It is correctly defaulted to `false`, and it is honestly labelled TEMPORARY.
The OIDC failure it was added to diagnose has been resolved. Leaving a
one-variable path from "PR author" to "account admin" in the tree is not worth
the diagnostic convenience.

**Remediation:** delete the variable and both conditional expressions.

### L-4 · JWKS cache does not refetch on unknown `kid`

**`api/index.mjs:57-66, 92-94`**

JWKS is cached for one hour. An unrecognised `kid` throws
`401 unknown signing key` rather than invalidating the cache and refetching.
When Cognito rotates signing keys, valid tokens are rejected for up to an hour.

Availability rather than security, and low impact at one user, but it will
present as an inexplicable sign-in failure that resolves itself.

**Remediation:** on `kid` miss, refetch once (guarded against repeated
refetches so an invalid `kid` cannot be used to hammer the JWKS endpoint)
before returning 401.

### L-5 · `sk` prefix allowlist matches without a delimiter check

**`api/index.mjs:196`**

```js
ALLOWED_SK_PREFIXES.some((p) => sk === p || sk.startsWith(p))
```

`"PROFILE"` carries no `#`, so `PROFILE_anything` passes. The prefixed entries
are safer, but the check still admits `WORKOUT#` followed by arbitrary
content, which is intended.

The allowlist's stated purpose is to stop a caller inventing item types.
Within the caller's own partition the impact is storing junk in their own
records, so this is a hardening nit.

**Remediation:** require either exact match or `p.endsWith("#") && sk.startsWith(p)`.

### L-6 · AWS account ID committed to a public repository

**`infra/versions.tf:19`, `index.html:2415`, `docs/*`**

Account `937485903079` appears in the state-bucket name, the Cognito hosted-UI
domain (`liftlog-937485903079.auth...`), and throughout the documentation.

AWS does not treat account IDs as secret, and the Cognito domain publishes it
to anyone who signs in regardless, so this cannot be fully avoided. It does
give an attacker a confirmed target for role-name enumeration and
cross-account trust probing. Recorded for completeness rather than action.

### L-7 · Two AWS access keys were exposed in screenshots — process finding

Two IAM access keys — ending `…MKND7` and `…PQOUR` — were exposed in
screenshots and have been rotated. Both are dead, and the repository history
is clean of key *material*: no `tfstate`, no `tfvars`, no secret access keys.

The IDs are deliberately truncated here. Written in full they match
`AKIA[0-9A-Z]{16}`, which is what both gitleaks and Trivy detect on — and
they did, on the first CI run, from this very paragraph. A scanner cannot
know a key is rotated, and it should not have to: the correct response to
"our secret scanner flagged our own security doc" is to stop writing
credentials into documentation, not to teach the scanner to ignore them. The
last four characters are enough to identify which keys these were.

The finding is not the keys but the absence of a control that would have
caught them. GitHub push protection is free on public repositories and would
have blocked both before they reached a commit; it is not yet enabled —
Settings → Code security → Secret scanning, enable both scanning and push
protection.

The durable fix is already largely in place: CI uses OIDC, so there are no
long-lived keys in the pipeline at all. The remaining long-lived credential is
the local `liftlog-tf` profile, which is at least MFA-gated.

### L-8 · Service worker caches navigation responses without checking status

**`sw.js:47-58`**

The navigation branch caches `res` unconditionally, unlike the static-asset
branch which checks `res.status === 200`. A 5xx page, or a captive-portal
interception response, can be written over the cached app shell and then
served as the offline fallback until the next successful load.

**Remediation:** mirror the status check from the asset branch.

### Informational

- **`api/index.mjs:96-101`** — `createPublicKey` is called on the JWK without
  asserting `kty === "RSA"`. The JWKS comes from Cognito over TLS so this is
  theoretical, but an explicit check costs one line.
- **`api/index.mjs:138-169`** — `handleGet` paginates until the partition is
  exhausted with no page cap. Bounded by the caller's own data volume.
- **`index.html:2434-2437`** — the PKCE verifier alphabet has 66 characters
  and is indexed by `byte % 66`, giving a slight modulo bias. At 64
  characters the verifier still carries ~380 bits; no practical impact.
- **`infra/modules/data/main.tf:45-48`** — the DynamoDB table intentionally
  uses the AWS-owned key rather than a CMK. Checkov will flag this
  (`CKV_AWS_119`); suppress it with the existing rationale rather than
  "fixing" it. A CMK costs ~$1/month for no meaningful gain on a
  single-tenant table.

---

## 7. Accepted risks

Decisions taken knowingly. Each is defensible for a single-user personal
project and each would need revisiting if that changed.

| Risk | Rationale | Revisit when |
|---|---|---|
| Auth tokens in `localStorage` | No safe alternative for a static SPA with no backend session. `httpOnly` cookies need a server. | Any multi-user deployment |
| No WAF or true rate limiting | CloudFront + WAF is real monthly cost for a one-user app. Budget alarm is the control. | Sustained abuse, or non-trivial user count |
| DynamoDB AWS-owned key, not a CMK | ~$1/month for no gain on single-tenant data | Regulated or multi-tenant data |
| Sync is not backup | Deletions replicate. Point-in-time recovery is the actual backup. | — |
| Apply role holds service wildcards on `*` | The account hosts one stack, so account-wide and stack-wide are the same set | This account hosts anything besides Lift Log |
| No Lambda code signing | Action pinning addresses the realistic path to modified code | More than one maintainer |
| 7-day log retention, no CMKs anywhere | Cost decisions on data that is either public or already encrypted | Regulated data, or an audit obligation |

## 8. Remediation summary

| ID | Severity | Status |
|---|---|---|
| H-1 | High | Escalation path fixed, pending apply · residual breadth accepted |
| H-2 | High | Fixed — defaults committed, pending apply |
| M-1 | Medium | Open — folds into Phase 5 |
| M-2 | Medium | Fixed — CSP + security headers in vercel.json |
| M-3 | Medium | Open |
| M-4 | Medium | Open |
| M-5 | Medium | Open — folds into Phase 5 |
| L-1 | Low | Fixed — 10 interpolations escaped, build 9 |
| L-2 | Low | Open |
| L-3 | Low | Open |
| L-4 | Low | Open |
| L-5 | Low | Open |
| L-6 | Low | Accepted |
| L-7 | Low | Keys rotated; push protection still to enable |
| L-8 | Low | Open |

Nothing High remains open, and M-2 and L-1 are closed. Suggested order for
the rest:

1. **M-4** — a two-line Terraform change plus enrolling an authenticator.
   Single-factor auth is now the weakest remaining link in the chain that
   protects the data.
2. **L-3** — delete `debug_allow_any_ref`. One variable stands between a pull
   request branch and the apply role.
3. **M-3** — replace the plan role's account-wide `ReadOnlyAccess` with a
   policy scoped to what `terraform plan` actually reads.
4. **L-4, L-5, L-8** — small correctness fixes, batchable.
5. **L-2** — add OAuth `state`. Currently redundant with PKCE, but only by
   coincidence.

M-1 and M-5 resolve together whenever Phase 5 happens; there is no reason to
build a CloudFront distribution solely for them.

## 6a. Automated scan results

`.github/workflows/security.yml` runs Checkov, Trivy, gitleaks, CodeQL and an
action-pinning check on every pull request, every push to `main`, and weekly.
The weekly run matters because new CVEs land against unchanged code.

Checkov against `infra/` at the time of writing:

```
passed: 99   failed: 0   skipped: 24   parsing errors: 0
```

Every one of the 24 suppressions is an inline `#checkov:skip` comment on the
resource itself, carrying a written reason. There is no skip list in the
workflow — a blanket list at the top of a config file is how a scanner
quietly stops working, and it puts the rationale somewhere nobody reads it
while editing the resource.

The suppressions divide into three kinds, and the distinction is worth
preserving when adding more:

1. **The check does not apply.** `CKV_AWS_116` wants a dead letter queue on a
   synchronously-invoked function; DLQs only catch async failures.
   `CKV_AWS_117` wants the Lambda in a VPC, which would cost $32/month in NAT
   gateway to reach an endpoint it must reach, protecting nothing.
2. **The check applies and the answer is a deliberate no.** `CKV_AWS_119`,
   `CKV_AWS_145`, `CKV_AWS_158`, `CKV_AWS_173` all want customer-managed KMS
   keys where the data is either already encrypted with a free key or is not
   secret at all. `CKV_AWS_338` wants a year of log retention, which inverts
   a deliberate cost decision.
3. **The check is right and the finding is tracked.** `CKV_AWS_301` and
   `CKV_AWS_258` are M-1 and M-5. They are suppressed because they are
   triaged, not because they are fine, and each suppression names the finding
   and the condition for removing it.

Kind 3 is the one to watch. A suppression that points at an open finding is
honest bookkeeping; a suppression that points at nothing is a finding that
has been deleted rather than fixed.

### Division of labour between scanners

The first CI run settled a question worth recording: **Checkov owns Terraform,
Trivy does not.**

Trivy was initially configured with `scanners: vuln,secret,misconfig`. Its
misconfiguration pass produced four HIGH findings and every one was a decision
Checkov had already been told about — `AWS-0132` twice for SSE-S3 rather than a
CMK (`CKV_AWS_145`), `AWS-0345` for `s3:*` in the apply role (`CKV_AWS_356`,
the H-1 residual), and `AWS-0136` for the SNS managed key. Trivy does not read
`#checkov:skip` comments, so silencing them would have meant a second
suppression file, in a second rule vocabulary, describing the same decisions —
guaranteed to drift out of step with the inline comments.

One finding was also wrong on its own terms. `AWS-0132` fired on the S3 access
log destination bucket, while the rule's own description states that "SSE-KMS
is not supported for S3 server access logging destination buckets; in such
cases, use SSE-S3 instead" — which is exactly what that bucket does.

`misconfig` is therefore disabled. Trivy runs `vuln,secret`, which is ground
Checkov does not cover at all. Two scanners that disagree are worth having;
two that repeat each other into an unmaintained ignore file are not.

Worth noting what this cost: nothing. Trivy reported zero vulnerabilities and
zero secrets on that same run.

Two limits worth stating plainly:

- **CodeQL does not see the application's JavaScript.** It extracts `.js` and
  `.mjs` files, and the app's code lives in an inline `<script>` block in
  `index.html`. So CodeQL covers `api/` only — and L-1, the unescaped-ID
  finding, is in exactly the code it cannot see. Extracting the script to its
  own file would fix that at the cost of the single-file property the PWA is
  built around.
- **Checkov reads Terraform, not AWS.** It cannot see configuration drift, so
  it would not have caught H-2. The plan-is-empty-after-apply check suggested
  in that finding is what covers this gap.

### Action pinning, and why it is not theoretical

Every `uses:` entry in both workflows is pinned to a commit SHA with the tag
preserved in a trailing comment. `scripts/pin-actions.sh` applies the pins and
`--check` fails the build if any entry is unpinned or its tag has since moved.

The justification arrived while setting this up. The workflow originally
referenced `aquasecurity/trivy-action@0.28.0`, and that tag no longer
resolves: trivy-action was the subject of a supply chain attack, and as part
of the response the maintainers migrated every tag to a `v` prefix and removed
the old unprefixed ones. A mutable tag pointing at attacker-controlled code is
the exact scenario pinning exists to prevent, and it happened to an action
this repository was about to trust with the same runner that holds AWS
credentials.

Two things follow. First, pinning is not paperwork here. Second, `--check`
failing on an unresolvable ref — rather than skipping it — is the behaviour
that surfaced this at all; a checker that quietly passed over what it could
not resolve would have left the stale reference in place.

**Pinning has a cost, and `.github/dependabot.yml` pays it.** A frozen SHA
never receives an upstream security fix. The script stops actions drifting
*unpinned*; Dependabot stops them drifting *outdated*. Either alone is a
half-measure — a pinned-and-abandoned action is its own supply chain risk,
just a slower one.

Workflows triggered by Dependabot pull requests receive a read-only
`GITHUB_TOKEN` and no secrets, regardless of the `permissions` block. That is
correct — a bot-authored PR should not be able to mint AWS credentials — so
the Terraform plan job, the CodeQL job and the SARIF uploads are conditioned
on `github.actor != 'dependabot[bot]'` rather than left to fail. The scans
themselves still run and still gate the build; only publishing to the
Security tab is skipped. Dependabot touches nothing but action pins, so
nothing meaningful goes unexamined.

## 9. Reference

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

Background and rationale for existing architectural decisions:
[`DECISIONS.md`](DECISIONS.md). CI scanning that enforces parts of this
document: [`.github/workflows/security.yml`](../.github/workflows/security.yml).
