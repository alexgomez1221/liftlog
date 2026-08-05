output "table_name" {
  description = "DynamoDB table holding all workout data."
  value       = module.data.table_name
}

output "table_arn" {
  description = "Table ARN — Phase 3 scopes the Lambda policy to it."
  value       = module.data.table_arn
}

output "user_pool_id" {
  value = module.auth.user_pool_id
}

output "client_id" {
  description = "Cognito app client ID for the browser."
  value       = module.auth.client_id
}

output "hosted_ui_url" {
  description = "Cognito hosted sign-in UI."
  value       = module.auth.hosted_ui_url
}

output "issuer" {
  description = "JWT issuer URL."
  value       = module.auth.issuer
}

output "api_url" {
  description = "Sync API endpoint. Phase 4 puts this in the app."
  value       = module.api.function_url
}

output "api_log_group" {
  description = "Tail with: aws logs tail <this> --follow"
  value       = module.api.log_group
}

output "login_url" {
  description = "Paste into a browser to test sign-up end to end."
  value       = "${module.auth.hosted_ui_url}/login?client_id=${module.auth.client_id}&response_type=code&scope=email+openid+profile&redirect_uri=${urlencode(var.callback_urls[0])}"
}

output "gha_plan_role_arn" {
  description = "GitHub variable AWS_PLAN_ROLE_ARN."
  value       = module.cicd.plan_role_arn
}

output "gha_apply_role_arn" {
  description = "GitHub variable AWS_APPLY_ROLE_ARN."
  value       = module.cicd.apply_role_arn
}

output "alerts_topic_arn" {
  value = module.observability.topic_arn
}

output "dashboard_url" {
  description = "CloudWatch dashboard."
  value       = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards/dashboard/${module.observability.dashboard_name}"
}
