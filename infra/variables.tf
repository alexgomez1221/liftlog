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
    including trailing slash. Add your deployed app URL here — the localhost
    entry is only useful if you serve the app locally.
  EOT
  type        = list(string)
  default     = ["http://localhost:8080/"]
}

variable "logout_urls" {
  description = "URLs Cognito may redirect to after sign-out. Same exact-match rule as callback_urls."
  type        = list(string)
  default     = ["http://localhost:8080/"]
}

variable "log_retention_days" {
  description = "CloudWatch log retention for the API. Logs default to never expiring, which is the most common source of unexpected cost on small accounts."
  type        = number
  default     = 7
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
