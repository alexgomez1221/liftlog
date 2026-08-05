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
