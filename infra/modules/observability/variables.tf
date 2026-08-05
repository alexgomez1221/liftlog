variable "name" {
  description = "Prefix for the SNS topic and dashboard."
  type        = string
}

variable "region" {
  description = "Region the dashboard widgets query."
  type        = string
}

variable "alert_email" {
  description = "Where alarms are sent. Leave empty to create the topic without a subscription."
  type        = string
  default     = ""
}

variable "function_name" {
  description = "Lambda function to chart."
  type        = string
}

variable "table_name" {
  description = "DynamoDB table to chart."
  type        = string
}

variable "log_group" {
  description = "Log group for the recent-errors widget."
  type        = string
}
