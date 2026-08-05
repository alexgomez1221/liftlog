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

output "login_url" {
  description = "Paste into a browser to test sign-up end to end."
  value       = "${module.auth.hosted_ui_url}/login?client_id=${module.auth.client_id}&response_type=code&scope=email+openid+profile&redirect_uri=${urlencode(var.callback_urls[0])}"
}
