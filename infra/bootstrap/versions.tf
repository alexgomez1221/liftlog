terraform {
  # 1.11+ required: native S3 state locking (use_lockfile) replaced the
  # deprecated dynamodb_table argument. Check yours with `terraform version`.
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = var.project
      ManagedBy = "terraform"
      Component = "bootstrap"
    }
  }
}
