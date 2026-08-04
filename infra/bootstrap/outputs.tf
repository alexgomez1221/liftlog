output "state_bucket" {
  description = "S3 bucket holding Terraform state for every other module."
  value       = aws_s3_bucket.tfstate.id
}

output "aws_account_id" {
  description = "Account these resources live in."
  value       = data.aws_caller_identity.current.account_id
}

output "backend_config" {
  description = "Paste this into infra/main.tf in Phase 2 to use the remote backend."
  value       = <<-EOT

    terraform {
      backend "s3" {
        bucket       = "${aws_s3_bucket.tfstate.id}"
        key          = "${var.project}/terraform.tfstate"
        region       = "${var.aws_region}"
        encrypt      = true
        use_lockfile = true
      }
    }

  EOT
}
