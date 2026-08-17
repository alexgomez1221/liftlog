variable "aws_region" {
  description = "Must match the region used in bootstrap. ACM certs for CloudFront also require us-east-1."
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Name prefix for all resources."
  type        = string
  default     = "liftlog"
}

variable "env" {
  description = "Environment name. Single environment for now, but naming resources with it avoids a painful rename if a dev stack is ever added."
  type        = string
  default     = "prod"
}

variable "callback_urls" {
  description = <<-EOT
    URLs Cognito may redirect to after a successful login. Must match exactly,
    including trailing slash. The localhost entry is only useful if you serve
    the app locally.

    The real value is committed as the default deliberately. These are public
    identifiers, not secrets — they are visible in the hosted UI redirect and
    in any browser's network tab. Previously the default was localhost-only
    and the real value lived only in gitignored terraform.tfvars, which meant
    CI ran with different inputs than a laptop: the apply job on merge to main
    silently rewrote the Cognito client's callback URLs to localhost and broke
    sign-in in production. Committing the value keeps CI and local plans
    identical. If this ever moves off Vercel, change it here.
  EOT
  type        = list(string)
  default     = ["https://liftlog-rust.vercel.app/", "http://localhost:8080/"]
}

variable "logout_urls" {
  description = "URLs Cognito may redirect to after sign-out. Same exact-match rule as callback_urls, and committed as a default for the same reason."
  type        = list(string)
  default     = ["https://liftlog-rust.vercel.app/", "http://localhost:8080/"]
}

variable "log_retention_days" {
  description = "CloudWatch log retention for the API. Logs default to never expiring, which is the most common source of unexpected cost on small accounts."
  type        = number
  default     = 14
}

variable "deletion_protection" {
  description = "Blocks accidental deletion of the DynamoDB table. Set false if you need `terraform destroy` to succeed."
  type        = bool
  default     = true
}

variable "github_repo" {
  description = "owner/repo, used to pin the OIDC sub claim for CI roles."
  type        = string
  default     = "alexgomez1221/liftlog"
}

variable "alert_email" {
  description = "Where CloudWatch alarms are sent. Supplied in CI as TF_VAR_alert_email so it stays out of the public repo."
  type        = string
  default     = ""
}

variable "create_oidc_provider" {
  description = "GitHub's OIDC provider is account-wide. Set false if one already exists."
  type        = bool
  default     = true
}


variable "github_owner_id" {
  description = "Numeric GitHub account ID — GitHub's OIDC sub claim embeds it. From https://api.github.com/users/<owner>."
  type        = string
  default     = "42987339"
}

variable "github_repo_id" {
  description = "Numeric GitHub repository ID. From https://api.github.com/repos/<owner>/<repo>."
  type        = string
  default     = "1319094575"
}

variable "allow_signup" {
  description = "Allow self-registration in the Cognito pool. False = invite-only, correct for a single-user app."
  type        = bool
  default     = false
}

variable "mfa_configuration" {
  description = <<-EOT
    Cognito MFA: OFF, OPTIONAL or ON.

    OPTIONAL, and each of the three values matters here. Read this before
    changing it — a wrong value locked this account out once already.

    OFF also disables software_token_mfa_configuration, and without that
    AssociateSoftwareToken fails with SoftwareTokenMFANotFoundException. So
    OFF is not merely "no MFA" — it makes enrolment impossible, including the
    in-app setup screen. It is the emergency setting, not a resting state.

    ON forces a challenge on every sign-in whether or not the user has a
    usable factor. The pool carries an orphaned TOTP association — enrolled
    through the hosted UI, authenticator entry then deleted, and AWS offers no
    way to remove a software token, only to replace it. Under ON, Cognito
    challenged that dead token and the account became unreachable.
    admin-set-user-mfa-preference did not help: the challenge follows the
    association, not the preference list, and UserMFASettingList read null
    throughout.

    OPTIONAL enables TOTP at the pool level (so enrolment works) while
    challenging only users who have MFA configured. That is what makes the
    in-app setup screen usable, and it replaces the orphaned association on
    first successful enrolment.

    Sequence to reach ON safely:
      1. Apply this at OPTIONAL and confirm sign-in still works.
      2. Enrol via Settings -> Two-factor authentication in the app.
      3. Confirm with admin-get-user that UserMFASettingList is populated.
      4. Only then set ON.

    If sign-in ever breaks: apply OFF, and immediately change this default to
    match. A -var flag does not persist, and a committed default higher than
    the applied state means the next CI apply re-locks the account — the same
    divergence as H-2.

    TOTP only. SMS is the weaker factor and costs per message.
  EOT
  type        = string
  default     = "ON"
}

variable "reserved_concurrency" {
  description = <<-EOT
    Lambda max concurrent executions. Bounds cost exposure from
    unauthenticated traffic. -1 means no reservation.

    Defaults to -1 because reserving concurrency is impossible on an account
    whose total Lambda concurrency quota is 10 — AWS refuses any reservation
    that would drop unreserved concurrency below 10, so on a default new
    account no positive value is accepted:

      InvalidParameterValueException: Specified ReservedConcurrentExecutions
      for function decreases account's UnreservedConcurrentExecution below
      its minimum value of [10]

    This is less of a loss than it looks. With one function in the account,
    the account-wide quota IS the cap — a flood is bounded at 10 concurrent
    executions either way. What the reservation adds is a guarantee that one
    runaway function cannot starve another, which only matters once there is
    a second function.

    To enable it: raise the Lambda "Concurrent executions" quota
    (L-B99A9384) to 100 or more, then set this to 5. Check the current value
    with:

      aws lambda get-account-settings --query 'AccountLimit.ConcurrentExecutions'

    See docs/SECURITY.md finding M-5.
  EOT
  type        = number
  default     = -1
}
