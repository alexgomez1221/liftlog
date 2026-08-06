/*
  Bootstrap — run once, before anything else.

  Solves the chicken-and-egg problem: remote state needs an S3 bucket, but
  creating that bucket is itself Terraform. So this module runs with LOCAL
  state, creates the bucket, and every other module then uses the S3 backend.

  It also creates the budget alarm, so the very first apply in this account
  puts a cost guardrail in place before any billable resource exists.
*/

data "aws_caller_identity" "current" {}

locals {
  # Bucket names are globally unique across all AWS accounts, so suffix with
  # the account ID rather than inventing something and hoping it's free.
  state_bucket_name = "${var.project}-tfstate-${data.aws_caller_identity.current.account_id}"
}

# ---------------------------------------------------------------------------
# Terraform state bucket
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "tfstate" {
  #checkov:skip=CKV_AWS_144:Cross-region replication is disaster-recovery for a region-loss event, at roughly double the storage cost plus request charges. State here is a few hundred KB, versioned, and reproducible from the repo by re-importing. Not proportionate for a personal project.
  #checkov:skip=CKV_AWS_145:SSE-S3 (AES256) is configured below and is free. Switching to SSE-KMS adds per-request KMS charges and a key to manage; the threat it addresses — an attacker with S3 read access but not KMS decrypt — does not exist in a single-principal account. See docs/SECURITY.md, Accepted risks.
  #checkov:skip=CKV2_AWS_62:Event notifications are an integration mechanism, not a control. There is nothing subscribed to state changes and no consumer to build. CloudTrail already records who wrote to this bucket.
  bucket = local.state_bucket_name

  # State files describe your whole infrastructure. Losing this bucket is far
  # worse than losing any single resource in it.
  lifecycle {
    prevent_destroy = true
  }
}

# ---------------------------------------------------------------------------
# Access logging for the state bucket
# ---------------------------------------------------------------------------
#
# State is the highest-value object in the account: it enumerates every
# resource and is the file an attacker would read to map the infrastructure.
# Server access logs are the record of who read it, and CloudTrail data
# events for S3 are billed per request whereas these are not.
#
# A separate bucket, because a bucket logging to itself generates a log
# object for every log write.

resource "aws_s3_bucket" "logs" {
  #checkov:skip=CKV_AWS_18:This IS the access-log target. Enabling access logging on it would log its own log deliveries, which grows without bound.
  #checkov:skip=CKV_AWS_144:Cross-region replication of access logs is not proportionate for a personal project.
  #checkov:skip=CKV_AWS_145:SSE-S3 is used deliberately. SSE-KMS on a log target adds a KMS request charge per delivered log object.
  #checkov:skip=CKV2_AWS_62:Nothing consumes these events.
  bucket = "${local.state_bucket_name}-logs"
}

resource "aws_s3_bucket_public_access_block" "logs" {
  bucket                  = aws_s3_bucket.logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "logs" {
  bucket = aws_s3_bucket.logs.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Logs are for investigating something recent. A year is generous.
resource "aws_s3_bucket_lifecycle_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id

  rule {
    id     = "expire-access-logs"
    status = "Enabled"

    filter {}

    expiration {
      days = 365
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }

    # Failed multipart uploads are invisible in the console but still billed.
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.logs]
}

# Grant the S3 logging service write access. The old way was the
# log-delivery-write canned ACL, which no longer works on buckets created
# with BucketOwnerEnforced (the default since April 2023) — ACLs are
# disabled entirely. A bucket policy is the current mechanism, and
# aws:SourceArn is what stops another account naming your bucket as its own
# log target.
resource "aws_s3_bucket_policy" "logs_delivery" {
  bucket = aws_s3_bucket.logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowS3ServerAccessLogDelivery"
        Effect    = "Allow"
        Principal = { Service = "logging.s3.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.logs.arn}/s3-access/*"
        Condition = {
          ArnLike      = { "aws:SourceArn" = aws_s3_bucket.tfstate.arn }
          StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
        }
      },
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.logs.arn,
          "${aws_s3_bucket.logs.arn}/*"
        ]
        Condition = {
          Bool = { "aws:SecureTransport" = "false" }
        }
      }
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.logs]
}

resource "aws_s3_bucket_logging" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  target_bucket = aws_s3_bucket.logs.id
  target_prefix = "s3-access/"

  depends_on = [aws_s3_bucket_policy.logs_delivery]
}

# Versioning is what makes a corrupted or truncated state recoverable.
resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Reject any request that isn't TLS. Cheap, and reviewers look for it.
resource "aws_s3_bucket_policy" "tfstate_tls_only" {
  bucket = aws_s3_bucket.tfstate.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource = [
        aws_s3_bucket.tfstate.arn,
        "${aws_s3_bucket.tfstate.arn}/*"
      ]
      Condition = {
        Bool = { "aws:SecureTransport" = "false" }
      }
    }]
  })

  depends_on = [aws_s3_bucket_public_access_block.tfstate]
}

# Old state versions pile up forever otherwise. 90 days is plenty of runway
# to recover from a bad apply without paying to store years of history.
resource "aws_s3_bucket_lifecycle_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 90
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.tfstate]
}

# ---------------------------------------------------------------------------
# Cost guardrail
# ---------------------------------------------------------------------------

resource "aws_budgets_budget" "monthly" {
  name         = "${var.project}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # Warn on the way up, not after the fact.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 50
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
  }

  # Forecasted spend catches a runaway on day 3 instead of day 30.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.alert_email]
  }
}
