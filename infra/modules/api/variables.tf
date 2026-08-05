variable "name" {
  description = "Function name, also used for the role, log group and alarms."
  type        = string
}

variable "source_dir" {
  description = "Directory containing index.mjs. Zipped at plan time — no npm install needed."
  type        = string
}

variable "table_name" {
  description = "DynamoDB table name, passed to the function as TABLE_NAME."
  type        = string
}

variable "table_arn" {
  description = "Table ARN. The IAM policy is scoped to exactly this resource."
  type        = string
}

variable "cognito_issuer" {
  description = "Expected iss claim. The function fetches signing keys from <issuer>/.well-known/jwks.json."
  type        = string
}

variable "cognito_client_id" {
  description = "Expected client_id claim. Tokens minted for a different app client are rejected."
  type        = string
}

variable "allowed_origins" {
  description = "Origins permitted by CORS. Keep this to your real app URLs — '*' would let any site call the API with a stolen token."
  type        = list(string)
}

variable "log_retention_days" {
  description = "CloudWatch retention. Left unset, logs never expire and cost accrues indefinitely."
  type        = number
  default     = 7
}

variable "alarm_actions" {
  description = "SNS topics notified when an alarm fires. An alarm with no actions changes state silently and tells nobody."
  type        = list(string)
  default     = []
}
