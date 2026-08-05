# Architecture decision records

Each entry: what was decided, what else was considered, why, and what would change the answer.

The second half covers bugs that changed the design. Those are included deliberately — a decision that survived contact with a real failure is worth more than one that was never tested.

---

## 1. Vanilla single-file app, not a framework

**Decided:** the entire client is one `index.html` — markup, styles and ~2,800 lines of JavaScript.

**Alternatives:** React with Vite (the stack I use on another project), Svelte, any SPA framework.

**Why:** deploying is copying a file. No build step, no `node_modules`, no toolchain to keep current, no bundler config to debug at 11pm. The app is one person's workout log; the complexity budget is better spent on sync correctness than on component architecture.

There's a real cost: no component model, and the file is long. Both are tolerable at this size and would not be at ten times it.

**Revisit** when a second developer joins, or when the UI needs virtualised lists or complex shared state. Porting to Expo would also be the moment, since a React Native rewrite subsumes this decision anyway.

---

## 2. localStorage is the source of truth

**Decided:** the client owns the data. The cloud is a replica, and every network call is best-effort.

**Alternatives:** cloud-first with a local cache; IndexedDB; a sync engine like Replicache.

**Why:** gyms have terrible signal. A cloud-first design fails exactly where the app is used. Logging a set must never wait on a network round-trip, and the app must be fully usable with the radio off.

localStorage over IndexedDB because the whole dataset is a few hundred KB of JSON, and synchronous access keeps the code simple.

**Revisit** if the dataset grows past a few MB, or if progress photos get added — those belong in IndexedDB or object storage, not localStorage.

---

## 3. DynamoDB single-table, not Aurora Postgres

**Decided:** one DynamoDB table, `PK = USER#<sub>`, `SK = <TYPE>#<id>`, on-demand billing.

**Alternatives:** Aurora Serverless v2 Postgres, RDS, Supabase.

**Why:** every current access pattern is user-scoped key-value. Aurora carries a floor cost even at zero traffic, which defeats the goal of running indefinitely on the always-free tier. DynamoDB on-demand costs nothing when nobody is lifting.

The honest tradeoff: no joins, and no ad-hoc queries. That's fine while every query starts with "this user's…".

**Revisit** the moment cross-user features appear — a social feed, exercise leaderboards, "people who do this also do…". Those are joins, and a document store starts costing more in application code than it saves in bill. The sort-key scheme was designed so a GSI (`GSI1PK = EXERCISE#<id>`) slots in without reshaping existing items.

---

## 4. Lambda function URL, not API Gateway

**Decided:** the API is a single Lambda behind a function URL.

**Alternatives:** API Gateway HTTP API, REST API, ALB.

**Why:** one consumer, one route. Usage plans, request validation and custom authorizers buy nothing here. API Gateway's free tier is 12-month; function URLs are free permanently.

**Revisit** for third-party API consumers, WAF, request throttling, or if CloudFront needs to sit in front with origin access control.

---

## 5. Hand-written JWT verification, not `aws-jwt-verify`

**Decided:** verify Cognito tokens with `node:crypto` — fetch JWKS, check `alg` against an allowlist, verify RS256, then validate `iss`, `aud`/`client_id`, `token_use`, `exp` and `nbf`.

**Alternatives:** `aws-jwt-verify` (AWS's own library), `jose`, `jsonwebtoken`.

**Why:** the library is the conventional choice and a reasonable one. Using it means bundling `node_modules` into the deployment zip, which means a build step before every `terraform apply`. Hand-verifying keeps deployment to a single command and the repo free of vendored dependencies.

The cost is real: the verification logic is now mine to get right, and JWT verification has sharp edges. Every one is covered by a test that actively attempts the attack — forged signature, tampered payload, `alg: none`, HS256 confusion, unknown `kid`, expired, wrong issuer, ID token presented as an access token.

**Revisit** if the token handling grows beyond one algorithm and one issuer. "Don't roll your own crypto" is sound advice; this is using a standard library primitive to check a standard signature, which is a different thing — but only barely, and only while it stays this small.

---

## 6. Last-write-wins, not CRDTs

**Decided:** conflicts resolve by comparing `updatedAt`. Newest wins.

**Alternatives:** CRDTs, operational transform, per-field merge, conflict prompts.

**Why:** one person can't be in two gyms simultaneously. Genuine concurrent edits are near-impossible, so the machinery to resolve them correctly would be complexity paid for a scenario that doesn't occur.

**Revisit** if routines become shareable or a coach can edit a client's program. Then two people really can edit the same record at once, and last-write-wins silently discards someone's work.

---

## 7. Tombstones for deletions

**Decided:** deleting a record writes `{sk, updatedAt, deleted: true}` rather than removing it. Tombstones are pruned after 90 days.

**Alternatives:** hard delete; a separate deletions log; never delete.

**Why:** without a tombstone, deleting on one device is undone by the next sync — the server still has the record, so the pull restores it. The delete has to be a fact that syncs, not an absence.

90 days because any device that hasn't synced in that long has an expired refresh token and will sign in fresh anyway.

Tombstone-versus-item conflicts resolve by timestamp like anything else, so a stale delete can't keep killing a record another device has recreated.

---

## 8. No VPC

**Decided:** Lambda runs outside any VPC and reaches DynamoDB over the public endpoint with SigV4 IAM auth.

**Alternatives:** private subnets with a NAT Gateway, or VPC endpoints.

**Why:** the traffic is already authenticated and encrypted. A VPC would add a NAT Gateway at roughly $32/month — more than every other component combined, several times over — for no meaningful security gain on a single-tenant workload.

This is a cost/benefit judgment rather than cargo-culting "private subnets are more secure". VPC endpoints would avoid the NAT cost but add complexity for the same non-benefit.

**Revisit** if anything ever needs to reach a private resource, or if a compliance regime requires network isolation regardless of the threat model.

---

## 9. Two CI roles with different trust scopes

**Decided:** `gha-plan` holds `ReadOnlyAccess` and is assumable from any workflow in this repo. `gha-apply` holds scoped write and is assumable only from `refs/heads/main`, matched with `StringEquals`.

**Alternatives:** one role for both; `AdministratorAccess` on the apply role.

**Why:** a pull request — including from a fork — should be able to show you a plan without being able to change anything. Collapsing them means anything that can open a PR can do whatever the role can.

`StringEquals` rather than `StringLike` on the apply role's branch ref: a wildcard would let a branch named `main-anything` assume it.

The plan role's condition *is* a wildcard on the event type, which is a deliberate asymmetry. It holds read-only permissions, the repository prefix is still exact, and pinning the event claim bought no security while costing significant time (see bug 6). Deciding where to be strict is more useful than being uniformly strict.

**Revisit** if the plan role ever gains write permissions, at which point the asymmetry stops being justified.

---

## 10. OIDC, not stored access keys

**Decided:** GitHub Actions authenticates by exchanging a short-lived OIDC token for temporary AWS credentials.

**Alternatives:** an IAM user's access keys in GitHub Secrets.

**Why:** there is nothing long-lived to leak and nothing to rotate. A compromised repository doesn't hand over standing AWS access. The `sub` condition pins the trust to this specific repository — without it, any repo on GitHub could assume the role, which is the single most commonly missed line in OIDC setups.

The same reasoning applies locally: the IAM user has no permissions of its own and can only assume an admin role, gated on MFA presence and a one-hour MFA age. Access keys alone are useless.

---

## 11. Terraform, not CDK or CloudFormation

**Decided:** Terraform, with state in S3 using native lockfile locking.

**Alternatives:** AWS CDK, CloudFormation, Pulumi.

**Why:** Terraform transfers across clouds and appears in more job listings. The plan/apply model reviews well in CI — a PR comment showing exactly what will change is hard to beat.

State locking uses `use_lockfile = true` rather than a DynamoDB lock table. Terraform 1.10 added native S3 locking via conditional writes and 1.11 deprecated `dynamodb_table`. Most tutorials still teach the lock table.

---

## 12. Warm-up sets excluded from volume, PRs and set counts

**Decided:** sets marked warm-up don't count toward volume, personal records, or per-muscle set totals.

**Why:** this is a product decision, not a technical one, and it's the kind that quietly determines whether the numbers are trustworthy. A lifter doesn't consider 135×10 before a 225×5 working set to be part of the session's volume. Counting it would inflate every metric and make week-over-week comparisons meaningless.

Secondary muscles count as half a set toward muscle-group totals — a compromise between ignoring them and overstating them.

---

# Bugs that changed the design

## 1. `load()` returned `null` instead of the default

`save(key, null)` writes the string `"null"`. `load()` did `v ? JSON.parse(v) : fallback` — and `"null"` is truthy, so it parsed to `null` and returned it. Any consumer expecting an array got `null` and threw on `.length`.

Found by a test that seeded deliberately hostile localStorage. It needed a specific sequence to trigger, but it would have white-screened the app.

**Fix:** fall back on missing keys, unparseable JSON, *and* a parsed `null`, plus a shape guard so an array-typed default never returns a non-array.

**Lesson:** "falsy" and "absent" aren't the same, and serialisation makes that gap wider than it looks.

---

## 2. iOS safe areas — the same bug in three places

`apple-mobile-web-app-status-bar-style: black-translucent` makes iOS render content *underneath* the Dynamic Island. The header sat behind it and the settings button was untappable — the island was intercepting the touch.

I fixed the app shell. Then the same bug appeared on modal sheets, because they're `position: fixed` and sit outside the shell that had been padded. Then the layout still had a dead strip at the foot, because iOS reports `innerHeight` as the screen height *minus* the status bar while laying content out from y=0.

**Fix:** an on-device diagnostic showing real `env()` values, screen height, viewport height and install state. That turned three rounds of guessing into one measurement — `safe-area 59/34 · vh 793 · screen 852` made the arithmetic obvious.

**Lesson:** when you can't reproduce locally, ship the instrument before shipping more fixes.

---

## 3. Sync pushed before pulling — silent data loss

The first sync has no `lastSyncAt`, so *every* local item counted as outgoing. Pushing first uploaded stale local records over newer remote ones, then the pull read back what had just been clobbered.

Caught by a test seeding a newer remote routine against an older local one. It would have surfaced in production as "my laptop overwrote my phone's workouts" — data loss with no error.

**Fix:** pull first, merge by timestamp, then push. Whatever gets pushed is already the winning version.

**Lesson:** the ordering of operations in a sync protocol is a correctness property, not an implementation detail. Test both directions of every conflict.

---

## 4. One malformed record broke everything

A `curl` test in Phase 3 wrote an item whose `data` had no `id` — so the duplicate check `o.id === 'w_test1'` never matched. Every sync appended another copy. Three syncs, three phantom workouts with `undefined` dates and `NaN` durations.

Worse, the API validates per item but rejects the whole batch, so that one bad record blocked every real workout from syncing.

**Fix:** three layers. Copy the envelope's `updatedAt` onto imported records; require identity fields before accepting a remote item; skip locally-invalid items rather than letting one poison the batch. Plus a migration that cleans records already stored.

**Lesson:** validating on the way in isn't enough once bad data has landed. The guard has to ship with a migration, or every device that synced during the broken window stays broken.

---

## 5. Function URLs need two permissions, not one

`authorization_type = "NONE"` means Lambda won't demand SigV4. It does **not** mean anyone may invoke the URL — that's a separate resource-based policy. Creating a function URL in the console adds it silently, so the requirement is invisible until you build it as code.

And since October 2025, URLs need **both** `lambda:InvokeFunctionUrl` and `lambda:InvokeFunction`. Granting only the first returns `403 AccessDeniedException` — identical to having no policy at all.

I initially had the right hypothesis, then abandoned it when `function_url_auth_type` turned out to be invalid on the `InvokeFunction` action. The error was narrower than I read it: that one *argument* was wrong, not the whole idea.

**Lesson:** when an experiment fails, check whether it falsified the hypothesis or just the implementation. And `aws lambda invoke` bypassing the URL entirely was the diagnostic that separated "my code is broken" from "my permissions are broken".

---

## 6. GitHub's OIDC `sub` claim is undocumented

CI failed with `Not authorized to perform sts:AssumeRoleWithWebIdentity` against a trust policy that looked perfect: right provider, right audience, `sub` exactly `repo:owner/repo:ref:refs/heads/main` as AWS's documentation specifies.

Four hypotheses eliminated — IAM propagation, session tagging, a stale thumbprint, a missing workflow permission — each ruled out by evidence rather than by trying the next thing.

The decisive move was a **negative** result. Widening the condition to `repo:owner/repo:*` *also* failed, which eliminated the entire sub-condition theory and proved the string itself was wrong in a way I hadn't imagined.

CloudTrail had the answer:

```
repo:alexgomez1221@42987339/liftlog@1319094575:ref:refs/heads/main
```

GitHub embeds **immutable numeric IDs** in the claim — `owner@ownerId/repo@repoId` — which appears in neither AWS's documentation nor any tutorial. The error names no condition, so the policy can look correct and never match.

**Fix:** pin the IDs. Stricter than the plain form anyway — renaming the account or repo now breaks the trust rather than silently preserving it, which is exactly why GitHub added them.

**Lesson:** when every hypothesis is consistent with the config being correct, the answer is in something you can't observe. Go find the log that records what was actually presented, rather than reasoning harder about what should have been.
