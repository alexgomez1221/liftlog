output "user_pool_id" {
  description = "User pool ID."
  value       = aws_cognito_user_pool.main.id
}

output "user_pool_arn" {
  description = "User pool ARN."
  value       = aws_cognito_user_pool.main.arn
}

output "client_id" {
  description = "App client ID. Public — it goes in the browser."
  value       = aws_cognito_user_pool_client.web.id
}

output "hosted_ui_domain" {
  description = "Hosted UI domain prefix."
  value       = aws_cognito_user_pool_domain.main.domain
}

output "hosted_ui_url" {
  description = "Full hosted UI base URL."
  value       = "https://${aws_cognito_user_pool_domain.main.domain}.auth.${data.aws_region.current.name}.amazoncognito.com"
}

output "issuer" {
  description = "JWT issuer. Phase 3's Lambda validates the iss claim against this and fetches signing keys from ${"$"}{issuer}/.well-known/jwks.json."
  value       = "https://cognito-idp.${data.aws_region.current.name}.amazonaws.com/${aws_cognito_user_pool.main.id}"
}

data "aws_region" "current" {}
