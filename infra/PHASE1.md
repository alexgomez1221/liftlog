# Phase 1 — Bootstrap

Goal: a secured AWS account, a budget alarm, and a Terraform state backend. No app resources yet.

Expected cost: **$0.00.** An empty S3 bucket and a budget are both free.

Work through these in order. Steps 1–3 are one-time account setup; if your account is already secured with MFA and SSO, skip to step 4.

---

## 1. Check which free tier you're on

Sign in to the AWS console → **Billing and Cost Management** → **Free tier**.

| What you see | What it means |
|---|---|
| A 12-month free tier with usage percentages | Legacy account, created before 15 July 2025. Nothing expires for a year. |
| Credits balance and a Free Plan expiry date | New account. The Free Plan ends after **6 months** or when credits run out. |

If you're on the new plan, note the expiry date somewhere you'll see it. When a Free Plan lapses there's a 90-day grace period and then **the account is closed and its resources deleted** — you convert to the Paid Plan before then. Nothing in this project costs meaningful money on the Paid Plan; the always-free allowances cover it.

Don't have an account yet? Create one at [aws.amazon.com](https://aws.amazon.com/) and pick the **Free Plan** at signup.

---

## 2. Secure the root user

The root user can do anything, including closing the account and changing billing. You'll use it roughly twice ever.

1. Sign in as root → click your account name (top right) → **Security credentials**
2. **Multi-factor authentication (MFA)** → Assign MFA device
3. Use an authenticator app (Google Authenticator, 1Password, Authy)
4. Confirm there are **no root access keys**. If any exist, delete them.

Then stop using root. Everything below uses a separate identity.

---

## 3. Create a non-root identity

> **Do not enable IAM Identity Center on a Free Plan account.**
>
> Identity Center requires an *organization instance* to grant AWS account access, and creating an AWS Organization **immediately converts the account to pay-as-you-go and expires your free tier credits**. The console warns about this on the enable screen.
>
> The "account instance" link offered on that page is not a workaround — [account instances do not support AWS account access](https://docs.aws.amazon.com/singlesignon/latest/userguide/identity-center-instances.html). They exist for AWS managed applications only. Permission sets for console and CLI access need the organization instance.

Instead, use an IAM user that holds **no permissions of its own** and can only assume an admin role, with MFA required. You still get short-lived credentials, and you keep your credits.

This is the pattern AWS recommended before Identity Center existed, and it's still correct. It's also a better interview answer than "I made an admin user," because it demonstrates privilege separation.

### 3a. Create the user

IAM → **Users** → Create user

- Name: anything you like. This guide writes it as `<USERNAME>` — substitute consistently in every policy and profile below, exactly as typed. IAM is case-sensitive.
- **Do not** attach any policies. It gets none.
- Create

Then open the user → **Security credentials**:

**Assign an MFA device — it must be an authenticator app.**

> Passkeys and security keys are **console-only**. AWS [does not support them in the CLI or API](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_credentials_mfa_fido_supported_configurations.html), because `assume-role` requires a 6-digit `--token-code` that a FIDO2 device cannot produce. If you register only a passkey, console sign-in works and every Terraform run fails.
>
> Tell them apart by ARN:
>
> | Device | ARN shape | Works with CLI |
> |---|---|---|
> | Authenticator app (TOTP) | `arn:aws:iam::<ACCOUNT_ID>:mfa/<device-name>` | ✅ |
> | Passkey / security key | `arn:aws:iam::<ACCOUNT_ID>:u2f/user/<USERNAME>/<id>` | ❌ |
>
> A user can hold up to 8 devices, so registering both is fine — passkey for console, authenticator app for CLI. Just make sure `mfa_serial` in step 3d points at the `mfa/` one.

Choose **Authenticator app**, scan the QR with Google Authenticator / 1Password / Authy, enter two consecutive codes. **Copy the resulting `mfa/...` ARN** — step 3d needs it.

Then **Access keys** → Create access key → Command Line Interface → save the key and secret.

Those keys can do literally nothing on their own. That's the point.

### 3b. Create the admin role

> **3a must be finished first.** IAM checks that the principal exists when you save the trust policy. If `<USERNAME>` doesn't exist yet — or the name differs by so much as capitalisation or a trailing space — you get:
>
> `Failed to create role LiftlogAdmin. Invalid principal in policy: "AWS":"arn:aws:iam::…:user/<USERNAME>"`
>
> That error means the user, not the syntax. Confirm the exact name under IAM → Users. If you created it moments ago, wait ~10 seconds and retry — IAM is eventually consistent.

A role has **two** policies and the wizard asks for them on separate steps. They are not interchangeable:

| | Step 1 — trust policy | Step 2 — permissions policy |
|---|---|---|
| Answers | *Who* may assume this role | *What* the role may do |
| Contains `Principal` | Yes, required | **No — invalid here** |
| What you do | Paste the JSON below | Select a managed policy |

Pasting the trust policy into Step 2 produces red markers on the `Principal` line. If you see that, you're on the wrong step.

**Step 1 — Select trusted entity.** Choose **Custom trust policy** and paste this, replacing `<ACCOUNT_ID>` with your account number (top right of the console):

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "AWS": "arn:aws:iam::<ACCOUNT_ID>:user/<USERNAME>" },
    "Action": "sts:AssumeRole",
    "Condition": {
      "Bool": { "aws:MultiFactorAuthPresent": "true" },
      "NumericLessThan": { "aws:MultiFactorAuthAge": "3600" }
    }
  }]
}
```

The two conditions are the security-relevant part: the role can only be assumed with MFA, and only within an hour of authenticating. A stolen access key alone is useless.

**Step 2 — Add permissions.** Leave it on **Use existing policy** (not "Create inline policy"), search `AdministratorAccess`, tick it. Nothing to paste here.

**Step 3 — Name, review, create.** Name it `LiftlogAdmin`.

### 3c. Let the user assume that role

Back on the `<USERNAME>` user → **Add permissions** → Create inline policy → JSON:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": "sts:AssumeRole",
    "Resource": "arn:aws:iam::<ACCOUNT_ID>:role/LiftlogAdmin"
  }]
}
```

Name it `AssumeLiftlogAdmin`. This is the user's only permission.

### 3d. Wire up the CLI

> **Prerequisite: the AWS CLI must be installed locally.** Steps 3a–3c were console-only, so this is the first step that needs it. If `aws --version` says "command not found", do [step 4](#4-install-tooling) now and come back.

> **Run this in Terminal on your Mac — not AWS CloudShell.**
>
> CloudShell is an ephemeral browser terminal running inside AWS. It already carries your console session's credentials, and anything you configure there is invisible to the Terraform you run locally. Your repo and your Terraform live on your Mac, so the profile has to as well.

> **Never paste access keys anywhere they can be captured** — screenshots, chat, issues, commit history. If a secret is ever exposed, deactivate and delete the key immediately (IAM → Users → your user → Security credentials → Access keys) and create a new one. Rotation takes a minute; assuming it's fine does not.

```bash
aws configure --profile liftlog-base
```

Enter the access key and secret, region `us-east-1`, output `json`.

Now add a second profile. `~/.aws/config` is a **file you edit**, not a command — typing the bare path just makes the shell try to execute it and fail with "Permission denied":

```bash
nano ~/.aws/config
```

Append, substituting your real values. `mfa_serial` must be the **authenticator app** device (`mfa/…`), never the passkey (`u2f/…`):

```ini
[profile liftlog]
role_arn       = arn:aws:iam::<ACCOUNT_ID>:role/LiftlogAdmin
source_profile = liftlog-base
mfa_serial     = arn:aws:iam::<ACCOUNT_ID>:mfa/<device-name>
region         = us-east-1
```

Save with `Ctrl+O`, Enter, then `Ctrl+X`.

Use it:

```bash
export AWS_PROFILE=liftlog
aws sts get-caller-identity
```

You'll be prompted for your MFA code. It should print the `LiftlogAdmin` role ARN — **not** the user ARN. The CLI caches the temporary credentials and re-prompts when they expire, so you enter a code roughly once per session.

### 3e. A third profile, for Terraform

The `liftlog` profile works for the AWS CLI but **not** for Terraform. Running `terraform plan` with it fails:

```
Error: assume role with MFA enabled, but AssumeRoleTokenProvider session option not set.
```

That isn't a misconfiguration. The AWS SDK deliberately refuses to prompt for an MFA code — blocking indefinitely on input that may never arrive is dangerous for an automated tool — so it errors instead. The CLI has no such restriction.

The fix is to let the CLI resolve credentials and pass them to Terraform. Add a third profile to `~/.aws/config`:

```ini
[profile liftlog-tf]
credential_process = aws configure export-credentials --profile liftlog
region             = us-east-1
```

`credential_process` makes the SDK shell out to the AWS CLI, which prompts for MFA and returns temporary credentials as JSON. Terraform never has to prompt.

Use this profile for every Terraform command:

```bash
export AWS_PROFILE=liftlog-tf
```

Put that in `~/.zshrc` so new terminals pick it up. Both profiles remain valid — `liftlog` for ad-hoc CLI work, `liftlog-tf` for Terraform — and either is fine for both, so defaulting to `liftlog-tf` is simplest.

**Per-session alternative,** if you'd rather not edit the config:

```bash
eval "$(aws configure export-credentials --profile liftlog --format env)"
```

That exports `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` and `AWS_SESSION_TOKEN` into the current shell. Same effect, but you re-run it when the session expires after about an hour.

### If you'd rather have Identity Center

It is the better long-term answer, and you'll want it eventually — the Free Plan closes the account after six months anyway, so you'll convert to pay-as-you-go regardless. The only question is whether to spend the credits now.

Recommendation: don't. This project costs roughly $0/month on the always-free tier, so the credits buy you nothing here — save them for experimenting with services that actually cost money. Convert to the Paid Plan and enable Identity Center later, and write up the migration. "I ran on IAM roles with MFA-conditioned assume-role, then migrated to Identity Center when the account moved into an organization" is a genuinely good thing to be able to explain.

---

## 4. Install tooling

> Needed before step 3d. If you worked straight through 3a–3c in the console, do this now.

Neither tool needs Homebrew. These are the official installers.

### AWS CLI

```bash
curl "https://awscli.amazonaws.com/AWSCLIV2.pkg" -o "AWSCLIV2.pkg"
sudo installer -pkg AWSCLIV2.pkg -target /
rm AWSCLIV2.pkg
```

### Terraform

> `brew install terraform` **does not work.** HashiCorp relicensed Terraform under the BUSL and it was removed from homebrew-core. Via Homebrew it's now `brew tap hashicorp/tap && brew install hashicorp/tap/terraform`; the direct download below avoids the issue entirely.

Apple Silicon (M1/M2/M3/M4). Check with `uname -m` — `arm64` means use this as written; `x86_64` means swap `arm64` for `amd64`:

```bash
cd ~/Downloads
TF_VER=$(curl -s https://api.github.com/repos/hashicorp/terraform/releases/latest | sed -n 's/.*"tag_name": "v\([^"]*\)".*/\1/p')
curl -LO "https://releases.hashicorp.com/terraform/${TF_VER}/terraform_${TF_VER}_darwin_arm64.zip"
unzip -o "terraform_${TF_VER}_darwin_arm64.zip"
sudo mv terraform /usr/local/bin/
rm "terraform_${TF_VER}_darwin_arm64.zip"
```

Blocked by Gatekeeper ("developer cannot be verified")?

```bash
sudo xattr -d com.apple.quarantine /usr/local/bin/terraform
```

### Verify

```bash
aws --version        # want v2.x
terraform version    # want 1.11+
```

If a command still isn't found right after installing, open a new Terminal window — zsh caches command locations and won't pick up a new binary until it rehashes.

### Homebrew (optional, worth having later)

Not required for this project, but it makes future tooling a one-liner:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
eval "$(/opt/homebrew/bin/brew shellenv)"
```

The last two lines are the part people miss on Apple Silicon: Homebrew installs to `/opt/homebrew`, which isn't on PATH by default, so `brew` stays "command not found" until you add it.

Verify — Terraform must be **1.11 or newer** for native S3 state locking:

```bash
terraform version
aws --version
aws sts get-caller-identity
```

That last command is the real test. It should prompt for your MFA code, then print an ARN ending in `assumed-role/LiftlogAdmin/...`.

If it prints `user/<USERNAME>` instead, `AWS_PROFILE` is pointing at the base profile — set `export AWS_PROFILE=liftlog`. If it errors, credentials aren't set up; go back to step 3.

---

## 5. Apply the bootstrap

The `infra/` folder goes in the root of your existing `liftlog` repo, alongside `index.html`.

```bash
cd <your-repo>/infra/bootstrap
cp terraform.tfvars.example terraform.tfvars
```

Open `terraform.tfvars` and set `alert_email` to your address.

**Pick a region now and don't change it later.** The default is `us-east-1`. If your console currently shows a different region (Ohio / us-east-2, say), that's just the console's last-used region — it doesn't constrain anything yet.

Stay with `us-east-1` unless you have a reason not to:

- ACM certificates used by CloudFront **must** live in us-east-1 regardless of where everything else is, so using it throughout avoids a confusing split later
- It's the cheapest region and gets new services first
- Latency differences are single-digit milliseconds for a personal app

If you'd rather use Ohio, set `aws_region = "us-east-2"` in `terraform.tfvars` and change the `region` in both `~/.aws/config` profiles to match. Moving regions after resources exist means recreating them, so decide before you apply.

Then make sure Terraform's profile is active — **`liftlog-tf`**, not `liftlog`. Using `liftlog` here fails with `AssumeRoleTokenProvider session option not set`; see [3e](#3e-a-third-profile-for-terraform):

```bash
export AWS_PROFILE=liftlog-tf
terraform init
terraform plan
```

`plan` prompts for your MFA code on its first AWS call.

Read the plan. You should see **7 resources to add** and nothing to change or destroy:

- `aws_s3_bucket.tfstate`
- `aws_s3_bucket_versioning.tfstate`
- `aws_s3_bucket_server_side_encryption_configuration.tfstate`
- `aws_s3_bucket_public_access_block.tfstate`
- `aws_s3_bucket_policy.tfstate_tls_only`
- `aws_s3_bucket_lifecycle_configuration.tfstate`
- `aws_budgets_budget.monthly`

Reading the plan before applying is the habit worth building. Then:

```bash
terraform apply
```

Type `yes`. It takes about 30 seconds.

---

## 6. Verify

```bash
terraform output
```

Save the `backend_config` block — Phase 2 pastes it into the root module.

Confirm the bucket rejects public access and unencrypted transport:

```bash
BUCKET=$(terraform output -raw state_bucket)
aws s3api get-public-access-block --bucket "$BUCKET"
aws s3api get-bucket-versioning  --bucket "$BUCKET"
```

Both should report everything enabled. And check the budget exists:

```bash
aws budgets describe-budgets --account-id "$(terraform output -raw aws_account_id)"
```

---

## 7. Commit

```bash
cd <your-repo>
git add -A
git commit -m "Phase 1: Terraform bootstrap — state backend and budget alarm"
git push
```

Check that `terraform.tfstate` and `terraform.tfvars` are **not** in the commit — the `.gitignore` handles it, but confirm with `git status` before pushing. `.terraform.lock.hcl` **should** be committed.

---

## What you built

| Resource | Purpose |
|---|---|
| S3 state bucket | Versioned, encrypted, TLS-only, private. Holds Terraform state for every later phase. |
| Native S3 locking | Prevents two applies racing. Uses S3 conditional writes — `dynamodb_table` was deprecated in Terraform 1.11 and no lock table is needed. |
| 90-day version expiry | Recovery runway without paying to store state history forever. |
| Budget alarm | Alerts at 50%, 100%, and forecast-over-100% of $5/month. |

### Worth understanding before moving on

**Why bootstrap is separate.** Remote state needs a bucket; creating the bucket is Terraform. So this module uses local state and everything else uses the S3 backend. If you ever lose the local `terraform.tfstate` here, you can `terraform import` the bucket back — you don't lose the bucket itself.

**Why `prevent_destroy` is on the bucket.** `terraform destroy` in this directory would otherwise delete the state for your entire infrastructure. The flag makes that fail loudly.

**Why the account ID is in the bucket name.** S3 bucket names are globally unique across every AWS customer. `liftlog-tfstate` was taken years ago.

---

## Next: Phase 2

DynamoDB table and Cognito user pool. Done when you can sign up through the hosted UI and receive a JWT.
