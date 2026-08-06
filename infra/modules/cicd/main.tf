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

    /*
      Scoped to this repository, but deliberately NOT to a specific event
      type. Without the repo prefix, any GitHub repository on the internet
      could assume this role — that prefix is the load-bearing part.

      The wildcard tail is a considered tradeoff rather than laziness. This
      role holds ReadOnlyAccess and nothing more: the worst a branch or
      workflow in this repo can do with it is read state it could already
      read. Pinning the exact event claim bought no security here and cost
      real time, because the pull_request sub isn't the documented
      repo:<owner>/<repo>:pull_request shape.

      The apply role — which can change infrastructure — keeps an exact
      match on the branch ref. That's where precision earns its keep.
    */
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${local.repo_claim}:*"]
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
  AdministratorAccess.

  IAM is split out from the rest deliberately. An earlier version granted
  iam:* on "*" alongside the other services, described as a service scope.
  It wasn't one: iam:* is a privilege-escalation primitive. Any principal
  holding it can create a role trusting itself, attach AdministratorAccess
  and assume it — or attach an admin policy to the role it is already using.
  The Deny statement below blocks destruction, not escalation, so it did
  nothing to constrain that path. Checkov flags the old shape under five
  separate checks (CKV_AWS_107/108/109/110 and CKV2_AWS_40).

  Since every resource in this stack is named liftlog-*, IAM writes scope
  cleanly to that prefix. The split is:

    IamRead   Get/List/Simulate on "*" — these actions largely do not
              support resource-level permissions, and reading IAM metadata
              is not the escalation risk.
    IamWrite  mutations, restricted to the roles, policies and OIDC provider
              Terraform actually manages here.

  See docs/SECURITY.md finding H-1.
*/
data "aws_iam_policy_document" "apply" {
  /*
    The six suppressions below all point at the same thing: statement 0
    grants service-level wildcards on Resource = "*".

    This is a real residual and is recorded as such in docs/SECURITY.md
    (H-1, "Residual breadth"). The escalation path these checks were
    originally firing on — iam:* — is closed, and CKV2_AWS_40 now passes.
    What remains is breadth: the apply role can act on any S3 bucket,
    DynamoDB table or Lambda in the account, not just this stack's.

    Accepted because this account hosts exactly one stack, so "any resource
    in the account" and "this stack's resources" are currently the same set.
    That is a property of the account, not of the policy, which is why it is
    suppressed with a condition rather than closed:

      Remove these suppressions and scope each service to its liftlog-*
      ARNs if this account ever hosts anything besides Lift Log.

    Scoping now would mean enumerating ARNs for eight services, several of
    which (cognito-idp:CreateUserPool, budgets:*) do not support
    resource-level permissions on the create actions at all — brittle, and
    it breaks on every new resource for a gain that is currently zero.
  */
  #checkov:skip=CKV_AWS_107:Breadth of service wildcards on Resource=*, accepted. See the comment above and docs/SECURITY.md H-1.
  #checkov:skip=CKV_AWS_108:Breadth of service wildcards on Resource=*, accepted. See the comment above and docs/SECURITY.md H-1.
  #checkov:skip=CKV_AWS_109:Breadth of service wildcards on Resource=*, accepted. See the comment above and docs/SECURITY.md H-1.
  #checkov:skip=CKV_AWS_110:The iam:* escalation path is closed; IAM writes are scoped to role/liftlog-* and policy/liftlog-*. Remaining flag is service wildcards. See docs/SECURITY.md H-1.
  #checkov:skip=CKV_AWS_111:Breadth of service wildcards on Resource=*, accepted. See the comment above and docs/SECURITY.md H-1.
  #checkov:skip=CKV_AWS_356:Breadth of service wildcards on Resource=*, accepted. See the comment above and docs/SECURITY.md H-1.
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
      "sts:GetCallerIdentity",
      "tag:GetResources",
    ]
    resources = ["*"]
  }

  # Terraform refreshes state on every run, which means reading every
  # resource it manages. These are read-only and mostly cannot be scoped.
  statement {
    sid    = "IamRead"
    effect = "Allow"
    actions = [
      "iam:Get*",
      "iam:List*",
      "iam:Simulate*",
      # AWS services create their own service-linked roles on first use.
      # Constrained by AWS to a fixed set of service paths, so this is not
      # an escalation route.
      "iam:CreateServiceLinkedRole",
    ]
    resources = ["*"]
  }

  /*
    The escalation-relevant half. Restricted to this stack's own names:
    liftlog-prod-api-role, liftlog-gha-plan, liftlog-gha-apply and their
    inline policies, plus the GitHub OIDC provider.

    PassRole is included and scoped — without it Terraform cannot attach the
    execution role to the Lambda. Unscoped PassRole is itself a well-known
    escalation path, which is why it must not fall back into the statement
    above.
  */
  statement {
    sid    = "IamWriteOwnStackOnly"
    effect = "Allow"
    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:UpdateRole",
      "iam:UpdateRoleDescription",
      "iam:UpdateAssumeRolePolicy",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:PassRole",
      "iam:CreatePolicy",
      "iam:DeletePolicy",
      "iam:CreatePolicyVersion",
      "iam:DeletePolicyVersion",
      "iam:SetDefaultPolicyVersion",
      "iam:TagPolicy",
      "iam:UntagPolicy",
    ]
    resources = [
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.name}-*",
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/${var.name}-*",
    ]
  }

  # The OIDC provider is account-wide and has no name prefix to match on,
  # so it gets its own statement pinned to the exact ARN.
  statement {
    sid    = "IamManageGithubOidcProvider"
    effect = "Allow"
    actions = [
      "iam:CreateOpenIDConnectProvider",
      "iam:DeleteOpenIDConnectProvider",
      "iam:UpdateOpenIDConnectProviderThumbprint",
      "iam:TagOpenIDConnectProvider",
      "iam:UntagOpenIDConnectProvider",
      "iam:AddClientIDToOpenIDConnectProvider",
      "iam:RemoveClientIDFromOpenIDConnectProvider",
    ]
    resources = [
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/token.actions.githubusercontent.com",
    ]
  }

  /*
    Even CI shouldn't be able to dismantle the account or mint itself a new
    identity. An explicit Deny beats any Allow, so this holds regardless of
    what the statements above grant.

    The IAM user actions are the escalation routes that survive resource
    scoping: a user created outside the liftlog-* prefix would be denied by
    the scoping alone, but denying the action outright means a future
    loosening of that prefix cannot silently reopen the path. Terraform
    manages no IAM users here, so nothing legitimate is lost.
  */
  statement {
    sid    = "DenyAccountDestructionAndIdentityCreation"
    effect = "Deny"
    actions = [
      "organizations:*",
      # Not account:* — the AWS provider calls account:GetRegionOptStatus
      # during region validation on some versions, and denying it would fail
      # every apply for no security gain.
      "account:CloseAccount",
      "account:DisableRegion",
      "iam:DeleteAccountPasswordPolicy",
      "s3:DeleteBucket",
      "iam:CreateUser",
      "iam:DeleteUser",
      "iam:CreateAccessKey",
      "iam:UpdateAccessKey",
      "iam:CreateLoginProfile",
      "iam:UpdateLoginProfile",
      "iam:AttachUserPolicy",
      "iam:PutUserPolicy",
      "iam:CreateSAMLProvider",
      "iam:UpdateSAMLProvider",
      "iam:DeleteRolePermissionsBoundary",
      "iam:DeleteUserPermissionsBoundary",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "apply" {
  name   = "${var.name}-gha-apply-policy"
  role   = aws_iam_role.apply.id
  policy = data.aws_iam_policy_document.apply.json
}
