variable "aws_region" {
  description = "Region for all resources. us-east-1 is the default: it's the cheapest, has every service, and ACM certificates for CloudFront MUST live there."
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Name prefix for all resources."
  type        = string
  default     = "liftlog"

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.project))
    error_message = "Project must be lowercase letters, numbers and hyphens (it becomes part of an S3 bucket name)."
  }
}

variable "alert_email" {
  description = "Email address for budget alerts. No SNS confirmation needed — AWS Budgets emails directly."
  type        = string

  validation {
    condition     = can(regex("^[^@]+@[^@]+\\.[^@]+$", var.alert_email))
    error_message = "alert_email must be a valid email address."
  }
}

variable "monthly_budget_usd" {
  description = "Monthly spend that triggers an alert. Expected steady-state cost is under $1, so 5 leaves headroom without hiding a problem."
  type        = number
  default     = 5
}
