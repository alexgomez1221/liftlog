/*
  Root module.

  Phase 2 wires up the two stateful pieces the API will need in Phase 3:
  a DynamoDB table for workout data, and a Cognito user pool for identity.
  Nothing here has a cost floor — both bill per use, with permanent free
  allowances that comfortably cover single-user traffic.
*/

locals {
  name = "${var.project}-${var.env}"
}

module "data" {
  source = "./modules/data"

  name                = local.name
  deletion_protection = var.deletion_protection
}

module "auth" {
  source = "./modules/auth"

  name          = local.name
  project       = var.project
  callback_urls = var.callback_urls
  logout_urls   = var.logout_urls
  allow_signup  = var.allow_signup
}

module "api" {
  source = "./modules/api"

  name       = "${local.name}-api"
  source_dir = "${path.root}/../api"

  table_name = module.data.table_name
  table_arn  = module.data.table_arn

  cognito_issuer    = module.auth.issuer
  cognito_client_id = module.auth.client_id

  # CORS origins are the app URLs minus the trailing slash — browsers send
  # Origin without a path, so "https://x.app/" never matches.
  allowed_origins = [for u in var.callback_urls : trimsuffix(u, "/")]

  log_retention_days   = var.log_retention_days
  alarm_actions        = [module.observability.topic_arn]
  reserved_concurrency = var.reserved_concurrency
}

module "observability" {
  source = "./modules/observability"

  name          = local.name
  region        = var.aws_region
  alert_email   = var.alert_email
  function_name = "${local.name}-api"
  table_name    = module.data.table_name
  log_group     = "/aws/lambda/${local.name}-api"
}

module "cicd" {
  source = "./modules/cicd"

  name                 = var.project
  github_repo          = var.github_repo
  create_oidc_provider = var.create_oidc_provider
  debug_allow_any_ref  = var.debug_allow_any_ref
  github_owner_id      = var.github_owner_id
  github_repo_id       = var.github_repo_id
}
