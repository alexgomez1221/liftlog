output "plan_role_arn" {
  description = "Set as the AWS_PLAN_ROLE_ARN variable in GitHub."
  value       = aws_iam_role.plan.arn
}

output "apply_role_arn" {
  description = "Set as the AWS_APPLY_ROLE_ARN variable in GitHub."
  value       = aws_iam_role.apply.arn
}
