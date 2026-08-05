variable "name" {
  description = "Prefix for the CI role names."
  type        = string
}

variable "github_repo" {
  description = "owner/repo. This pins the OIDC sub claim — without it, any GitHub repository could assume these roles."
  type        = string

  validation {
    condition     = can(regex("^[^/]+/[^/]+$", var.github_repo))
    error_message = "github_repo must be in owner/repo form, e.g. alexgomez1221/liftlog."
  }
}

variable "default_branch" {
  description = "Branch permitted to assume the apply role."
  type        = string
  default     = "main"
}

variable "create_oidc_provider" {
  description = "Set false if token.actions.githubusercontent.com already exists in this account — it's account-wide, and a second one conflicts."
  type        = bool
  default     = true
}
