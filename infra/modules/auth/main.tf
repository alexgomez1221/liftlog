/*
  Cognito user pool.

  The pool issues JWTs. Phase 3's Lambda verifies them and reads the `sub`
  claim to scope every DynamoDB query — the client never gets to say which
  user's data it wants, which is what makes the authorization model sound.

  Free tier covers 10,000 monthly active users. This will have one.
*/

data "aws_caller_identity" "current" {}

resource "aws_cognito_user_pool" "main" {
  name = var.name

  # Sign in with an email address rather than a separate username.
  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  username_configuration {
    case_sensitive = false
  }

  password_policy {
    minimum_length    = 12
    require_lowercase = true
    require_uppercase = true
    require_numbers   = true
    # Symbols deliberately not required. Length does far more for entropy
    # than character-class rules, which mostly push people toward
    # Password1! and a sticky note.
    require_symbols = false
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  admin_create_user_config {
    /*
      Self-signup is CLOSED by default.

      An open pool lets anyone on the internet register. They can't read your
      data — every partition key is derived from their own `sub` — but they
      can store their own records in your table, consume your free tier, and
      give an attacker a legitimate token with which to probe the API.

      This is a single-user app, so there is no reason for registration to be
      open. Create additional users with:

        aws cognito-idp admin-create-user \
          --user-pool-id <id> --username <email>

      Set allow_signup = true if the app ever becomes multi-tenant.
    */
    allow_admin_create_user_only = !var.allow_signup
  }

  # Cognito sends verification mail from a shared AWS address, capped at 50
  # messages/day. Fine for personal use; a real product would wire in SES.
  email_configuration {
    email_sending_account = "COGNITO_DEFAULT"
  }

  deletion_protection = "ACTIVE"

  # Pools default to the Essentials tier. Lite is cheaper but drops features
  # like advanced security; both include the same 10,000 MAU free allowance,
  # so there's nothing to gain by switching at this scale.
}

# Hosted UI. Saves building sign-up, sign-in, email verification and password
# reset screens — all of which are easy to get subtly wrong.
resource "aws_cognito_user_pool_domain" "main" {
  # Domain prefixes are globally unique across all AWS accounts, so suffix
  # with the account ID rather than hoping "liftlog" is free.
  domain       = "${var.project}-${data.aws_caller_identity.current.account_id}"
  user_pool_id = aws_cognito_user_pool.main.id
}

resource "aws_cognito_user_pool_client" "web" {
  name         = "${var.name}-web"
  user_pool_id = aws_cognito_user_pool.main.id

  # No client secret: this runs in a browser, where nothing is secret. PKCE
  # protects the authorization code flow instead.
  generate_secret = false

  explicit_auth_flows = [
    "ALLOW_USER_SRP_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH",
  ]

  supported_identity_providers = ["COGNITO"]

  allowed_oauth_flows                  = ["code"]
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_scopes                 = ["email", "openid", "profile"]

  callback_urls = var.callback_urls
  logout_urls   = var.logout_urls

  # Short-lived access tokens, long-lived refresh. The app silently refreshes,
  # so a stolen access token is only useful for an hour.
  access_token_validity  = 1
  id_token_validity      = 1
  refresh_token_validity = 30

  token_validity_units {
    access_token  = "hours"
    id_token      = "hours"
    refresh_token = "days"
  }

  # Returns a generic "incorrect username or password" instead of revealing
  # whether an account exists. Blocks user enumeration.
  prevent_user_existence_errors = "ENABLED"

  enable_token_revocation = true
}
