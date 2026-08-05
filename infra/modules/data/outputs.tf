output "table_name" {
  description = "DynamoDB table name."
  value       = aws_dynamodb_table.main.name
}

output "table_arn" {
  description = "Table ARN. Phase 3 scopes the Lambda IAM policy to exactly this resource."
  value       = aws_dynamodb_table.main.arn
}
