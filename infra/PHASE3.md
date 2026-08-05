# Phase 3 — Sync API

Goal: a Lambda that verifies Cognito JWTs and serves `GET`/`POST /sync` against DynamoDB.

Done when `curl` with a bearer token writes a workout and reads it back.

Expected cost: **$0.00.** Lambda's 1M requests and 400k GB-seconds per month never expire, and function URLs are free.

---

## 1. Apply

Nothing to install. The handler has no npm dependencies — the AWS SDK v3 ships inside the `nodejs20.x` runtime — so Terraform zips `api/` directly.

```bash
cd <your-repo>/infra
export AWS_PROFILE=liftlog-tf
terraform init      # picks up the new module
terraform plan
```

Expect **8 to add**: the function, function URL, the URL's invoke permission, IAM role, role policy, log group, and two alarms.

The `archive_file` and `aws_iam_policy_document` blocks show as `will be read during apply` rather than counting toward the total — they're data sources, which Terraform computes rather than creates.

```bash
terraform apply
```

---

## 2. Get an access token

The API needs a real Cognito access token. The browser flow gives you a `?code=`, which must be exchanged at the token endpoint.

Sign in:

```bash
open "$(terraform output -raw login_url)"
```

After authenticating you land on your app with `?code=XXXX` in the address bar. Copy that value, then:

```bash
CODE='paste-the-code-here'
CLIENT_ID=$(terraform output -raw client_id)
DOMAIN=$(terraform output -raw hosted_ui_url)
REDIRECT='https://liftlog-rust.vercel.app/'

curl -s -X POST "$DOMAIN/oauth2/token" \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d "grant_type=authorization_code&client_id=$CLIENT_ID&code=$CODE&redirect_uri=$REDIRECT"
```

You get back `access_token`, `id_token`, `refresh_token`. Grab the access token:

```bash
TOKEN='paste-the-access_token-here'
API=$(terraform output -raw api_url)
```

**Codes are single-use and expire in about 60 seconds.** If the exchange returns `invalid_grant`, sign in again for a fresh one. Access tokens last an hour.

---

## 3. Round-trip a workout

Write:

```bash
curl -s -X POST "${API}sync" \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"items":[{
        "sk":"WORKOUT#2026-08-04#w_test1",
        "type":"workout",
        "updatedAt":"2026-08-04T18:00:00.000Z",
        "data":{"name":"Leg Day","exercises":[{"exId":"squat_barbell","sets":[{"weight":225,"reps":5}]}]}
      }]}'
```

Expect `{"serverTime":"...","written":1}`.

Read it back:

```bash
curl -s "${API}sync" -H "Authorization: Bearer $TOKEN"
```

Your item comes back with `sk`, `type`, `updatedAt`, `deleted:false`, and `data`. **That's Phase 3 complete.**

Incremental sync — only what changed since a timestamp:

```bash
curl -s "${API}sync?since=2026-08-04T00:00:00.000Z" -H "Authorization: Bearer $TOKEN"
```

---

## 4. Prove the security actually works

Worth running these once. A security control you haven't tested is a security control you're guessing about.

```bash
# No token
curl -s -o /dev/null -w '%{http_code}\n' "${API}sync"
# 401

# Forged token
curl -s -o /dev/null -w '%{http_code}\n' "${API}sync" -H "Authorization: Bearer eyJhbGciOiJub25lIn0.eyJzdWIiOiJhZG1pbiJ9."
# 401

# Item type that isn't allowlisted
curl -s "${API}sync" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -X POST -d '{"items":[{"sk":"ADMIN#1","updatedAt":"2026-08-04T18:00:00.000Z"}]}'
# 400

# Trying to write into someone else's partition
curl -s "${API}sync" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -X POST -d '{"items":[{"sk":"WORKOUT#x","updatedAt":"2026-08-04T18:00:00.000Z","PK":"USER#victim"}]}'
# 200 — but written under YOUR sub, because the handler ignores client PK
```

Confirm that last one landed in your own partition, not the victim's:

```bash
aws dynamodb scan --table-name "$(terraform output -raw table_name)" \
  --projection-expression "PK,SK" --query 'Items[].PK.S' --output text | sort -u
```

Only one `USER#...` value, and it's yours.

---

## 5. Watch the logs

```bash
aws logs tail "$(terraform output -raw api_log_group)" --follow
```

Useful while wiring up the client in Phase 4. Retention is 7 days, deliberately.

---

## 6. Commit

```bash
cd <your-repo>
git add -A
git commit -m "Phase 3: sync API on Lambda with JWT verification"
git push
```

The zip Terraform builds lands in `infra/modules/api/.build/` and is gitignored — it's a build artifact, reproducible from source.

---

## How it works

### Authorization in one line

```js
PK: `USER#${sub}`   // sub comes from the verified token, never the request
```

The client never states which user's data it wants. It can't — the partition key is derived from a signature it cannot forge. Every query and every write is scoped by that one value.

### JWT verification, in order

| Check | Why it matters |
|---|---|
| `alg === "RS256"` | Trusting `header.alg` is the classic JWT hole. `none` skips verification; an HMAC alg lets an attacker sign using the public key as the shared secret. |
| `kid` found in JWKS | Pins to a key Cognito actually published. |
| Signature verifies | Proves the token is untampered. |
| `exp` / `nbf` | A valid signature on an expired token is still an expired token. |
| `iss` matches your pool | Otherwise any Cognito pool on AWS would be accepted. |
| `token_use === "access"` | ID tokens are for the client, access tokens for APIs. They're not interchangeable. |
| `client_id` matches | Rejects tokens minted for a different app client in the same pool. |

Signature verification alone proves only that *someone* signed it. The claim checks prove *who*, *for what*, and *when*.

### IAM, deliberately narrow

```hcl
actions   = ["dynamodb:Query", "dynamodb:BatchWriteItem"]
resources = [var.table_arn]
```

Not `dynamodb:*`, not `Resource = "*"`, and not the `AWSLambdaBasicExecutionRole` managed policy — that one grants `logs:*` across every log group in the account. Logging permission here is scoped to this function's own group.

The trust policy also carries `aws:SourceAccount`, so only Lambda in *your* account can assume the role. That's the confused-deputy guard.

### Decisions worth defending

**Function URL over API Gateway.** One consumer, no need for usage plans or request validation. API Gateway's free tier is 12 months; function URLs are free permanently. Revisit for third-party consumers or WAF.

**`authorization_type = "NONE"`.** Not "no auth" — the JWT is the auth. `AWS_IAM` would require the browser to hold AWS credentials and sign with SigV4, which a public SPA can't do safely.

`NONE` only means Lambda won't demand SigV4 — it authenticates nobody, but it still *authorizes* against the resource-based policy. That needs **two** `aws_lambda_permission` resources:

```hcl
# scoped by auth type
action                 = "lambda:InvokeFunctionUrl"
function_url_auth_type = "NONE"

# no function_url_auth_type — invalid on this action
action                 = "lambda:InvokeFunction"
```

For URLs created **after October 2025**, AWS checks both. Granting only `InvokeFunctionUrl` returns `403 AccessDeniedException` on every request — indistinguishable from having no policy at all, which makes it genuinely hard to diagnose. Creating a URL in the console adds both silently, so the requirement only surfaces when you build it as code.

`function_url_auth_type` is valid solely alongside `InvokeFunctionUrl`; pairing it with `InvokeFunction` fails with `InvalidParameterValueException`.

### Diagnosing a 403

Strip the auth header. The result tells you which layer is refusing:

```bash
curl -i "${API}sync"                              # no Authorization header
aws lambda invoke --function-name liftlog-prod-api \
  --cli-binary-format raw-in-base64-out \
  --payload '{"requestContext":{"http":{"method":"GET","path":"/sync"}},"headers":{}}' \
  /tmp/out.json && cat /tmp/out.json
```

| curl | direct invoke | Meaning |
|---|---|---|
| 401 missing bearer token | — | URL and handler both fine; it's your token |
| 403 Forbidden | 401 from handler | Function is healthy, resource policy is the problem |
| 403 Forbidden | error | The function itself is broken |

Direct invoke bypasses the URL entirely, which is what separates "my code is wrong" from "my permissions are wrong".

Diagnosing this is quicker if you strip the auth header first:

```bash
curl -i "${API}sync"      # no Authorization header
```

A `401 {"error":"missing bearer token"}` means the URL is fine and your handler is running. A `403 Forbidden` means the request never got there, so it's the resource policy — not your token, not your code.

**No npm dependencies.** `aws-jwt-verify` is the conventional choice and a reasonable one. Hand-verifying with `node:crypto` keeps the deploy to a single `terraform apply` with no build step or `node_modules` in the repo. The tradeoff is that the verification logic is now yours to get right — which is why every check above has a test behind it.

**BatchWriteItem retry loop.** Batch writes can partially succeed under throttling and return `UnprocessedItems`. Retrying with exponential backoff is required for correctness; without it, writes silently vanish.

**CORS origins, not `*`.** A wildcard would let any website call your API with a token it managed to steal.

---

## Next: Phase 4

Wire the app to this API — login, token storage and refresh, and the offline-first sync loop with last-write-wins conflict resolution.
