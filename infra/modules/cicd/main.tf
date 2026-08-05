/*
  GitHub Actions access via OIDC.

  No AWS access keys in GitHub secrets. GitHub mints a short-lived OIDC
  token for each workflow run, AWS verifies it against GitHub's public keys,
  and hands back temporary credentials. Nothing long-lived exists to leak,
  and there's no key rotation to forget.

  Two roles, deliberately:

    plan  — read-only, assumable from pull requests
    apply — write, assumable ONLY from the default branch

  A pull request from a fork can therefore read plan output but cannot
  change infrastructure. Collapsing these into one role is the common
  shortcut and it means any PR that runs CI can do anything the role can.
*/

data "aws_caller_identity" "current" {}

# GitHub's OIDC identity provider. The thumbprint list is no longer
# validated by AWS for this provider — it verifies against GitHub's JWKS
# directly — but the argument remains required.
resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 1 : 0

  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

locals {
  owner = split("/", var.github_repo)[0]
  name  = split("/", var.github_repo)[1]

  /*
    GitHub embeds immutable numeric IDs in the OIDC sub claim:

      repo:<owner>@<ownerId>/<repo>@<repoId>:ref:refs/heads/main

    not the plain repo:<owner>/<repo>:... that AWS docs and most tutorials
    show. Matching the plain form fails with a bare "Not authorized to
    perform sts:AssumeRoleWithWebIdentity" and no indication why — the only
    way to see the real claim is the CloudTrail event for the failed call.

    Pinning the IDs is also stricter: renaming the user or repo doesn't
    silently keep the trust alive, which is precisely why GitHub added them.
  */
  repo_claim = (
    var.github_owner_id != "" && var.github_repo_id != ""
    ? "${local.owner}@${var.github_owner_id}/${local.name}@${var.github_repo_id}"
    : var.github_repo
  )

  # Parenthesised so the ternary can wrap without HCL treating the newline
  # as the end of the expression.
  oidc_arn = (
    var.create_oidc_provider
    ? aws_iam_openid_connect_provider.github[0].arn
    : "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/token.actions.githubusercontent.com"
  )
}

# ---------------------------------------------------------------------------
# Plan role — pull requests, read only
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "plan_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_arn]
    }

    # aud pins the token to AWS STS. Without it, a token minted for any
    # other audience would be accepted.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # sub pins it to this repository. Without it, ANY GitHub repository in
    # the world could assume this role — the single most important line here.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        var.debug_allow_any_ref
        ? "repo:${local.repo_claim}:*"
        : "repo:${local.repo_claim}:pull_request"
      ]
    }
  }
}

resource "aws_iam_role" "plan" {
  name               = "${var.name}-gha-plan"
  assume_role_policy = data.aws_iam_policy_document.plan_trust.json
  max_session_duration = 3600
}

resource "aws_iam_role_policy_attachment" "plan_readonly" {
  role       = aws_iam_role.plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# ReadOnlyAccess covers reading state from S3. Plan runs with -lock=false in
# CI precisely so this role never needs write access to the state bucket.

# ---------------------------------------------------------------------------
# Apply role — default branch only, write access
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "apply_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Exact match on the branch ref, not StringLike. A wildcard here would
    # let a pull request branch assume the apply role.
    #
    # debug_allow_any_ref switches to StringLike with a repo-wide wildcard,
    # purely to bisect an authorization failure. Not a permanent setting.
    condition {
      test     = var.debug_allow_any_ref ? "StringLike" : "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        var.debug_allow_any_ref
        ? "repo:${local.repo_claim}:*"
        : "repo:${local.repo_claim}:ref:refs/heads/${var.default_branch}"
      ]
    }
  }
}

resource "aws_iam_role" "apply" {
  name               = "${var.name}-gha-apply"
  assume_role_policy = data.aws_iam_policy_document.apply_trust.json
  max_session_duration = 3600
}

/*
  Scoped to the services this stack actually uses rather than
  AdministratorAccess. It still includes iam:* because Terraform manages the
  Lambda execution role and these CI roles themselves — a genuinely
  privileged grant, and the honest tradeoff is documented rather than hidden
  behind a managed policy.
*/
data "aws_iam_policy_document" "apply" {
  statement {
    sid    = "ManageStackServices"
    effect = "Allow"
    actions = [
      "s3:*",
      "dynamodb:*",
      "lambda:*",
      "cognito-idp:*",
      "logs:*",
      "cloudwatch:*",
      "sns:*",
      "budgets:*",
      "iam:*",
      "sts:GetCallerIdentity",
      "tag:GetResources",
    ]
    resources = ["*"]
  }

  # Even CI shouldn't be able to dismantle the account.
  statement {
    sid    = "DenyAccountDestruction"
    effect = "Deny"
    actions = [
      "organizations:*",
      "account:CloseAccount",
      "iam:DeleteAccountPasswordPolicy",
      "s3:DeleteBucket",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "apply" {
  name   = "${var.name}-gha-apply-policy"
  role   = aws_iam_role.apply.id
  policy = data.aws_iam_policy_document.apply.json
}
