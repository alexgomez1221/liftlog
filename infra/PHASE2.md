# Phase 2 — Data and identity

Goal: a DynamoDB table for workouts and a Cognito user pool that issues JWTs.

Done when you can sign up through the hosted UI and decode a token containing your user `sub`.

Expected cost: **$0.00.** DynamoDB on-demand has no idle charge and 25 GB is always free; Cognito's free tier covers 10,000 monthly active users.

---

## 1. Configure

```bash
cd <your-repo>/infra
cp terraform.tfvars.example terraform.tfvars
nano terraform.tfvars
```

`callback_urls` is the only value worth thinking about. Cognito matches redirect URLs **exactly** — protocol, host, port, path, trailing slash. A mismatch produces `redirect_mismatch` at login with no further explanation.

If your app is live on Vercel, list both:

```hcl
callback_urls = ["https://your-app.vercel.app/", "http://localhost:8080/"]
logout_urls   = ["https://your-app.vercel.app/", "http://localhost:8080/"]
```

You can change these later with a `terraform apply` — nothing is baked in permanently. Leaving it as localhost only is fine for this phase, since the goal is just to prove sign-up works; add your real app URL before Phase 4 wires the browser up to it.

---

## 2. Apply

```bash
export AWS_PROFILE=liftlog-tf
terraform init
terraform plan
```

`init` is doing something new here: connecting to the S3 backend built in Phase 1. Watch for `Successfully configured the backend "s3"`. From now on state lives in the bucket, not on your laptop, and `use_lockfile` prevents two applies colliding.

Expect **4 resources to add**:

- `module.data.aws_dynamodb_table.main`
- `module.auth.aws_cognito_user_pool.main`
- `module.auth.aws_cognito_user_pool_domain.main`
- `module.auth.aws_cognito_user_pool_client.web`

Two data sources (`aws_region`, `aws_caller_identity`) are read during planning but aren't resources and don't appear in the count.

A couple of lines in the plan look odd but are fine. `client_secret = (sensitive value)` appears despite `generate_secret = false` — Terraform is tracking an attribute that comes back empty. `server_side_encryption (known after apply)` is DynamoDB confirming it will encrypt at rest with the free AWS-owned key, which is exactly what omitting the block is meant to achieve.

Then:

```bash
terraform apply
```

Cognito user pool creation takes about a minute — slower than most resources.

---

## 3. Verify

```bash
terraform output
```

You'll get `table_name`, `user_pool_id`, `client_id`, `hosted_ui_url`, `issuer`, and `login_url`.

### Confirm the table

```bash
aws dynamodb describe-table --table-name "$(terraform output -raw table_name)" \
  --query 'Table.{Status:TableStatus,Billing:BillingModeSummary.BillingMode,Keys:KeySchema}'
```

`ACTIVE`, `PAY_PER_REQUEST`, and a PK/SK schema.

### Sign up

```bash
open "$(terraform output -raw login_url)"
```

Create an account with a real email — Cognito sends a verification code. Password needs 12+ characters with upper, lower, and a digit.

After verifying you'll be redirected to your callback URL with `?code=...` in the address bar. **The page itself will fail to load** if nothing is running there. That's expected and not an error — Phase 4 adds the code that handles this. All you need right now is proof the account exists:

```bash
aws cognito-idp list-users \
  --user-pool-id "$(terraform output -raw user_pool_id)" \
  --query 'Users[].{Email:Attributes[?Name==`email`].Value|[0],Status:UserStatus}'
```

`CONFIRMED` means the pool is working end to end.

### Look at a token

Optional, but worth doing once — it makes the authorization model concrete:

```bash
aws cognito-idp admin-initiate-auth \
  --user-pool-id "$(terraform output -raw user_pool_id)" \
  --client-id "$(terraform output -raw client_id)" \
  --auth-flow ADMIN_USER_PASSWORD_AUTH \
  --auth-parameters USERNAME=you@example.com,PASSWORD='your-password'
```

That flow isn't enabled on the client (deliberately — it sends the password to the server, where SRP doesn't), so it will fail. To see a real token, paste one from the browser after Phase 4 into [jwt.io](https://jwt.io/) and look at the payload:

```json
{
  "sub": "a1b2c3d4-...",
  "iss": "https://cognito-idp.us-east-1.amazonaws.com/us-east-1_XXXX",
  "token_use": "access",
  "exp": 1234567890
}
```

`sub` is the whole point. Phase 3's Lambda reads it from the **verified** token and builds `PK = USER#<sub>` from it. The client never states which user's data it wants, so it cannot ask for someone else's.

---

## 4. Commit

```bash
cd <your-repo>
git add -A
git commit -m "Phase 2: DynamoDB table and Cognito user pool"
git push
```

`git status` should show no `.tfstate` — state is in S3 now. `terraform.tfvars` stays ignored; the `.example` is committed.

---

## What you built

| Resource | Purpose | Cost |
|---|---|---|
| DynamoDB table | All workout data, single-table design | $0 (25 GB always free) |
| Point-in-time recovery | Restore to any second in the last 35 days | Fractions of a cent at this size |
| Cognito user pool | Identity, email verification, password reset | $0 (10,000 MAU free) |
| Hosted UI | Sign-up and sign-in screens | $0 |
| App client | Public SPA client, OAuth code flow | $0 |

### Decisions worth being able to defend

**On-demand billing, not provisioned.** Provisioned capacity is cheaper at sustained high throughput but charges whether or not anyone uses the app. On-demand costs nothing at idle. Revisit if traffic ever becomes steady and predictable.

**No `server_side_encryption` block.** DynamoDB always encrypts at rest. Omitting the block uses the AWS-owned key, which is free; setting `enabled = true` switches to an AWS-managed KMS key and adds per-request KMS charges. On a single-tenant table that buys nothing. It would matter if you needed to audit key usage in CloudTrail or control the key's lifecycle.

**Two independent delete guards.** `prevent_destroy` stops Terraform; `deletion_protection_enabled` stops the console and API. They cover different paths — a colleague clicking Delete in the console isn't stopped by your lifecycle block.

**Public client with no secret.** Anything shipped to a browser is readable, so a client secret would be theatre. PKCE secures the authorization code flow instead, which is the current OAuth guidance for SPAs.

**Authorization code flow, not implicit.** Implicit puts tokens in the URL fragment, where they land in browser history and referrer headers. It's been discouraged for years.

**1-hour access tokens, 30-day refresh.** Short access tokens limit the damage from a leaked one; the long refresh token means you aren't signing in constantly. `enable_token_revocation` lets you kill a session immediately if needed.

**Symbols not required in passwords.** Length dominates entropy. Character-class requirements mostly produce `Password1!` and a sticky note. 12 characters with three classes is stronger in practice than 8 with four.

---

## Next: Phase 3

Lambda with a function URL, JWT verification, and the `GET`/`POST /sync` endpoints. Done when `curl` with a bearer token round-trips a workout item.
