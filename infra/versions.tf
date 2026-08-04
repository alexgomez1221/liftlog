terraform {
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Remote state, created by infra/bootstrap in Phase 1.
  # use_lockfile uses S3 conditional writes for locking — the dynamodb_table
  # argument was deprecated in Terraform 1.11 and no lock table is needed.
  backend "s3" {
    bucket       = "liftlog-tfstate-937485903079"
    key          = "liftlog/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = var.project
      Env       = var.env
      ManagedBy = "terraform"
    }
  }
}
