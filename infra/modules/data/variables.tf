variable "name" {
  description = "Table name."
  type        = string
}

variable "deletion_protection" {
  description = "Blocks deletion via API or console. Independent of Terraform's prevent_destroy lifecycle rule — both are set, since they guard different paths."
  type        = bool
  default     = true
}
