variable "name" {
  description = "User pool name."
  type        = string
}

variable "project" {
  description = "Used for the hosted UI domain prefix, which must be globally unique and lowercase alphanumeric with hyphens."
  type        = string
}

variable "callback_urls" {
  description = "Exact URLs Cognito may redirect to after login."
  type        = list(string)
}

variable "logout_urls" {
  description = "Exact URLs Cognito may redirect to after logout."
  type        = list(string)
}

variable "mfa_configuration" {
  description = "OFF, OPTIONAL or ON. Currently OFF — an orphaned TOTP association makes any other value a lockout. See the root variable of the same name and docs/SECURITY.md M-4 before changing."
  type        = string
  default     = "OFF"

  validation {
    condition     = contains(["OFF", "OPTIONAL", "ON"], var.mfa_configuration)
    error_message = "mfa_configuration must be OFF, OPTIONAL or ON."
  }
}

variable "allow_signup" {
  description = "Whether anyone can self-register in the pool. False means invite-only via admin-create-user — correct for a single-user app."
  type        = bool
  default     = false
}
