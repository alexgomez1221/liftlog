output "function_name" {
  description = "Lambda function name."
  value       = aws_lambda_function.api.function_name
}

output "function_url" {
  description = "Public HTTPS endpoint. Authorization is the Cognito JWT, not IAM."
  value       = aws_lambda_function_url.api.function_url
}

output "role_arn" {
  description = "Execution role ARN."
  value       = aws_iam_role.lambda.arn
}

output "log_group" {
  description = "CloudWatch log group name."
  value       = aws_cloudwatch_log_group.lambda.name
}
