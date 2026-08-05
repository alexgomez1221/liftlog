# Phase 6 — CI/CD and observability

Goal: infrastructure changes deploy from GitHub with no AWS keys stored anywhere, and alarms actually reach you.

Done when a pull request posts a `terraform plan` as a comment and merging it applies.

Expected cost: **$0.00.** GitHub Actions is free on public repos; SNS email and CloudWatch dashboards are free at this volume.

---

## 1. Apply the roles first

The CI roles have to exist before GitHub can assume them, so this apply runs from your laptop.

```bash
cd <your-repo>/infra
export AWS_PROFILE=liftlog-tf
terraform init
terraform plan
```

Expect roughly **9 to add**: the OIDC provider, two IAM roles with their policies, the SNS topic and subscription, the dashboard, and updates to the two existing alarms.

If you want alarm emails, set your address first — otherwise the topic is created without a subscription:

```bash
echo 'alert_email = "you@example.com"' >> terraform.tfvars
```

```bash
terraform apply
```

**Check your inbox.** SNS email subscriptions sit in "pending confirmation" until you click the link. Terraform reports the subscription as created either way, so a successful apply does not mean alerts work.

---

## 2. Wire up GitHub

```bash
terraform output gha_plan_role_arn
terraform output gha_apply_role_arn
```

In your repo → **Settings → Secrets and variables → Actions**:

**Variables** tab → New repository variable:

| Name | Value |
|---|---|
| `AWS_PLAN_ROLE_ARN` | the plan role ARN |
| `AWS_APPLY_ROLE_ARN` | the apply role ARN |

**Secrets** tab → New repository secret:

| Name | Value |
|---|---|
| `ALERT_EMAIL` | your email address |

Role ARNs are variables rather than secrets deliberately — they aren't credentials, they're identifiers, and having them visible in logs makes failures far easier to debug. The email is a secret only to keep it out of a public repo.

---

## 3. Test it

```bash
git checkout -b test-ci
```

Make a trivial change — bump `log_retention_days` from 7 to 14 in `variables.tf`:

```bash
git commit -am "test: CI plan" && git push -u origin test-ci
```

Open a pull request. Within a minute the workflow should post a comment containing the plan diff. Merge it, and the apply job runs against `main`.

Revert afterwards if you don't actually want 14 days.

---

## What this proves

### No long-lived credentials

There is no `AWS_ACCESS_KEY_ID` anywhere in this repository. GitHub mints a short-lived OIDC token per workflow run; AWS validates it against GitHub's public keys and returns temporary credentials that expire in an hour. Nothing to leak, nothing to rotate, and a compromised repo doesn't hand over standing AWS access.

### Two roles, not one

| Role | Trusted from | Permissions |
|---|---|---|
| `liftlog-gha-plan` | `repo:<owner>/<repo>:pull_request` | `ReadOnlyAccess` |
| `liftlog-gha-apply` | `repo:<owner>/<repo>:ref:refs/heads/main` | Scoped write |

A pull request — including one from a fork — can run a plan and read state, but cannot change infrastructure. Collapsing both into a single role is the common shortcut, and it means anything that can open a PR can do anything the role can.

Note the apply trust uses `StringEquals` on the exact branch ref, not `StringLike`. A wildcard there would let a branch named `main-something` assume the apply role.

### The `sub` condition is the important line

```hcl
condition {
  test     = "StringLike"
  variable = "token.actions.githubusercontent.com:sub"
  values   = ["repo:${var.github_repo}:pull_request"]
}
```

Without it, **any** GitHub repository on the internet could assume the role — the OIDC provider trusts GitHub as an issuer, not your repo specifically. This is the single most commonly missed condition in OIDC setups and the one worth being able to explain.

### Plan runs with `-lock=false`

The plan role is read-only and can't write the state lock object. That's fine: a plan changes nothing, and the apply that follows takes a real lock. It also means a long-running PR plan can't block an apply.

### Apply runs a saved plan

```bash
terraform plan -out=tfplan
terraform apply tfplan
```

Applying a freshly-computed plan risks executing something different from what was reviewed, if state drifted in between. Applying the saved file guarantees the changes are exactly the ones planned.

### Alarms that actually alarm

The Phase 3 alarms had no `alarm_actions`, which meant they changed state silently. An alarm nobody is told about is a dashboard widget. They now publish to SNS, with `ok_actions` too so you're told when things recover rather than being left wondering.

---

## Dashboard

```bash
terraform output dashboard_url
```

Four widgets — Lambda invocations/errors/throttles, duration average and max, DynamoDB consumed capacity, and DynamoDB throttles/user errors — plus a log widget filtering recent errors.

Worth glancing at after the first real sync from your phone. Duration on a cold start will be noticeably higher than on a warm one, which is the clearest illustration of what cold starts actually cost.

---

## Troubleshooting

**`Not authorized to perform sts:AssumeRoleWithWebIdentity`** — the `sub` condition doesn't match what GitHub actually sent.

The trap: **GitHub embeds immutable numeric IDs in the sub claim.** The real value is

```
repo:<owner>@<ownerId>/<repo>@<repoId>:ref:refs/heads/main
```

not the `repo:<owner>/<repo>:...` shown in AWS's documentation and essentially every tutorial. Matching the plain form fails with a bare "Not authorized" and no hint as to which condition was rejected — the trust policy can look completely correct while never matching.

The only way to see the claim that was actually presented is the CloudTrail event for the failed call:

CloudTrail → Event history → Event name `AssumeRoleWithWebIdentity` → open a failed event → View event record. `userIdentity.userName` is the sub.

Find your IDs:

```bash
curl -s https://api.github.com/users/<owner>        | grep '"id"'
curl -s https://api.github.com/repos/<owner>/<repo> | grep '"id"'
```

and set `github_owner_id` / `github_repo_id`. Pinning the IDs is stricter than the plain form anyway: renaming the user or repository breaks the trust rather than silently keeping it alive, which is exactly why GitHub added them.

A useful bisection when this happens: set `debug_allow_any_ref = true` to widen the condition to `repo:<claim>:*`. If it still fails, the sub isn't the problem at all and you can stop looking at it — which is how the ID format was eventually found here.

**`Credentials could not be loaded`** — `permissions: id-token: write` is missing from the workflow, or the role ARN variable isn't set in GitHub.

**`EntityAlreadyExists: OIDC provider`** — the provider is account-wide and something else already created it. Set `create_oidc_provider = false` in `terraform.tfvars`.

**Plan comment doesn't appear** — `pull-requests: write` permission, and note that PRs from forks get a read-only token by design.

**No alarm emails** — confirm the SNS subscription from your inbox. `aws sns list-subscriptions-by-topic --topic-arn "$(terraform output -raw alerts_topic_arn)"` shows `PendingConfirmation` if you haven't.

---

## Next: Phase 7

README with an architecture diagram, and the decision records. You already have the material — this conversation is full of real decisions with real tradeoffs, including several bugs that changed the design.
