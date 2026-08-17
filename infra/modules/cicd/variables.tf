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

variable "github_owner_id" {
  description = <<-EOT
    Numeric GitHub account ID. GitHub embeds immutable IDs in the OIDC sub
    claim — repo:<owner>@<ownerId>/<repo>@<repoId>:... — rather than the
    plain owner/repo shown in most documentation.

    Find it at https://api.github.com/users/<owner> (the "id" field).
    Leave empty to fall back to the legacy plain form.
  EOT
  type        = string
  default     = ""
}

variable "github_repo_id" {
  description = "Numeric repository ID, from https://api.github.com/repos/<owner>/<repo> (the \"id\" field)."
  type        = string
  default     = ""
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
