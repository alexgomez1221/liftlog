/*
  Single-table DynamoDB design.

  Every item is keyed PK = USER#<cognito-sub>, SK = <TYPE>#<id>. That one
  composite key satisfies every current access pattern:

    all data for a user      Query PK = USER#sub
    incremental sync         same query, filtered on updatedAt
    workouts in a date range Query PK = USER#sub, SK BETWEEN WORKOUT#a AND WORKOUT#b
    single item              GetItem
    delete                   PutItem with deleted = true (tombstone)

  No GSI yet. One becomes necessary only for cross-user access — a social
  feed or exercise leaderboards — at which point GSI1PK = EXERCISE#<id> or
  FEED#<follower> slots in without reshaping existing items.
*/

resource "aws_dynamodb_table" "main" {
  # checkov:skip=CKV_AWS_119:AWS-owned key is deliberate. DynamoDB always encrypts at rest; a CMK costs ~$1/month and adds key management for no meaningful gain on a single-tenant table only this account's Lambda can read. Revisit if the data ever becomes multi-tenant or regulated. See docs/SECURITY.md, Accepted risks.
  name = var.name

  # On-demand: no provisioned capacity, therefore no idle cost. Provisioned
  # would be cheaper at sustained high volume, but bills whether or not
  # anyone is using the app.
  billing_mode = "PAY_PER_REQUEST"

  hash_key  = "PK"
  range_key = "SK"

  attribute {
    name = "PK"
    type = "S"
  }

  attribute {
    name = "SK"
    type = "S"
  }

  # Continuous backups with 35-day restore-to-any-second. Billed on table
  # size, so a few MB of workout history costs fractions of a cent.
  point_in_time_recovery {
    enabled = true
  }

  # Deliberately no server_side_encryption block. DynamoDB always encrypts
  # at rest; omitting this uses the AWS-owned key, which is free. Setting
  # enabled = true switches to an AWS-managed KMS key and adds KMS charges
  # for no meaningful security gain on a single-tenant table.

  deletion_protection_enabled = var.deletion_protection

  lifecycle {
    # Guards against a rename silently destroying and recreating the table,
    # which would take every workout with it.
    prevent_destroy = true
  }
}
