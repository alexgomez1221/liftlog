/*
  Sync API: one Lambda behind a function URL.

  No API Gateway. With a single consumer there's nothing to gain from usage
  plans, request validation or custom authorizers, and API Gateway's free
  tier expires after 12 months where a function URL is free permanently.
  Revisit if the API ever gains third-party consumers or needs WAF.
*/

data "aws_caller_identity" "current" {}

# Zips the source directory at plan time. The handler has no npm
# dependencies — the AWS SDK v3 ships with the nodejs20.x runtime — so
# there is no build step and nothing to install before applying.
data "archive_file" "lambda" {
  type        = "zip"
  source_dir  = var.source_dir
  output_path = "${path.module}/.build/${var.name}.zip"
}

# Created explicitly rather than letting Lambda auto-create it. An
# auto-created log group has retention set to "never expire", which
# quietly accrues cost forever and is the most common surprise line item
# on small AWS accounts.
resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${var.name}"
  retention_in_days = var.log_retention_days
}

resource "aws_iam_role" "lambda" {
  name = "${var.name}-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
      # Confused-deputy guard: only this account's Lambda service may
      # assume the role, not Lambda in some other account.
      Condition = {
        StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
      }
    }]
  })
}

# Least privilege, deliberately. Three actions on exactly one table ARN —
# no dynamodb:*, no Resource = "*", no AWSLambdaBasicExecutionRole managed
# policy (which grants logs:* across every log group in the account).
data "aws_iam_policy_document" "lambda" {
  statement {
    sid    = "WriteOwnLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["${aws_cloudwatch_log_group.lambda.arn}:*"]
  }

  statement {
    sid    = "AccessWorkoutTable"
    effect = "Allow"
    actions = [
      "dynamodb:Query",
      "dynamodb:BatchWriteItem",
    ]
    resources = [var.table_arn]
  }
}

resource "aws_iam_role_policy" "lambda" {
  name   = "${var.name}-policy"
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.lambda.json
}

resource "aws_lambda_function" "api" {
  function_name = var.name
  role          = aws_iam_role.lambda.arn

  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256

  runtime = "nodejs20.x"
  handler = "index.handler"

  # 512 MB is well past what this needs, but Lambda scales CPU with memory
  # and the free tier is measured in GB-seconds. More memory finishing
  # sooner often costs the same or less than less memory running longer.
  memory_size = 512
  timeout     = 15

  environment {
    variables = {
      TABLE_NAME         = var.table_name
      COGNITO_ISSUER     = var.cognito_issuer
      COGNITO_CLIENT_ID  = var.cognito_client_id
      NODE_OPTIONS       = "--enable-source-maps"
    }
  }

  # Without this, the first invocation races Lambda into creating its own
  # log group with no retention, and ours is ignored.
  depends_on = [
    aws_cloudwatch_log_group.lambda,
    aws_iam_role_policy.lambda,
  ]
}

/*
  Required, and easy to miss. authorization_type = "NONE" only says Lambda
  won't demand SigV4 — it does NOT by itself permit anyone to invoke the
  URL. Without this resource-based policy every request returns:

    {"Message":"Forbidden. For troubleshooting Function URL authorization
     issues, see https://docs.aws.amazon.com/lambda/latest/dg/urls-auth.html"}

  Creating a function URL in the console adds this permission silently,
  which is why the omission is invisible until you build it with Terraform.

  principal = "*" is correct here: the endpoint is meant to be publicly
  reachable, and authorization is the Cognito JWT the handler verifies.
*/
resource "aws_lambda_permission" "function_url" {
  statement_id           = "AllowPublicFunctionUrlInvoke"
  action                 = "lambda:InvokeFunctionUrl"
  function_name          = aws_lambda_function.api.function_name
  principal              = "*"
  function_url_auth_type = "NONE"
}

/*
  Second grant, required for function URLs created after October 2025:
  AWS now checks lambda:InvokeFunction as well as lambda:InvokeFunctionUrl.
  With only the latter, every request returns 403 AccessDeniedException —
  identical to having no policy at all, which makes it hard to diagnose.

  Note the missing function_url_auth_type. That argument is only valid
  alongside lambda:InvokeFunctionUrl; pairing it with lambda:InvokeFunction
  fails with InvalidParameterValueException.

  Granting InvokeFunction to "*" is broader than the URL grant, since it
  isn't scoped by auth type. The exposure is small: invoking the function
  directly still lands in the handler, which rejects anything without a
  valid Cognito JWT. The alternative — putting CloudFront with OAC in front
  and scoping this to the distribution — is the right move if this ever
  stops being a personal project.
*/
resource "aws_lambda_permission" "function_invoke" {
  statement_id  = "AllowPublicFunctionInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api.function_name
  principal     = "*"
}


resource "aws_lambda_function_url" "api" {
  function_name = aws_lambda_function.api.function_name

  # The JWT is the authorization. AWS_IAM here would require the browser to
  # hold AWS credentials and sign requests with SigV4, which a public SPA
  # cannot do safely.
  authorization_type = "NONE"

  cors {
    allow_origins = var.allowed_origins

    # OPTIONS is deliberately absent. Function URLs answer preflight
    # themselves, and the API rejects it: allowMethods members are capped at
    # 6 characters, which is AWS's roundabout way of excluding it. Valid
    # values are GET, PUT, POST, HEAD, PATCH, DELETE or "*".
    allow_methods = ["GET", "POST"]

    allow_headers     = ["authorization", "content-type"]
    max_age           = 3600
    allow_credentials = false
  }
}

# Errors and throttles should be visible without going looking for them.
resource "aws_cloudwatch_metric_alarm" "errors" {
  alarm_name          = "${var.name}-errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.api.function_name
  }
}

resource "aws_cloudwatch_metric_alarm" "throttles" {
  alarm_name          = "${var.name}-throttles"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Throttles"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.api.function_name
  }
}
