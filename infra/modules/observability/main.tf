/*
  Alerting and a dashboard.

  The Lambda alarms created in Phase 3 had no alarm_actions, which means
  they changed state silently — an alarm nobody is told about is a dashboard
  widget, not an alert. This wires them to SNS.
*/

resource "aws_sns_topic" "alerts" {
  name = "${var.name}-alerts"
}

# Email subscriptions require confirming a link. Terraform creates the
# subscription in "pending confirmation" until you click it, and reports it
# as created either way — so check your inbox rather than trusting apply.
resource "aws_sns_topic_subscription" "email" {
  count = var.alert_email == "" ? 0 : 1

  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = var.name

  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric", x = 0, y = 0, width = 12, height = 6
        properties = {
          title  = "API — invocations and errors"
          region = var.region
          view   = "timeSeries"
          stat   = "Sum"
          period = 300
          metrics = [
            ["AWS/Lambda", "Invocations", "FunctionName", var.function_name],
            [".", "Errors", ".", "."],
            [".", "Throttles", ".", "."]
          ]
        }
      },
      {
        type = "metric", x = 12, y = 0, width = 12, height = 6
        properties = {
          title  = "API — duration (ms)"
          region = var.region
          view   = "timeSeries"
          period = 300
          metrics = [
            ["AWS/Lambda", "Duration", "FunctionName", var.function_name, { stat = "Average" }],
            ["...", { stat = "Maximum" }]
          ]
        }
      },
      {
        type = "metric", x = 0, y = 6, width = 12, height = 6
        properties = {
          title  = "DynamoDB — consumed capacity"
          region = var.region
          view   = "timeSeries"
          stat   = "Sum"
          period = 300
          metrics = [
            ["AWS/DynamoDB", "ConsumedReadCapacityUnits", "TableName", var.table_name],
            [".", "ConsumedWriteCapacityUnits", ".", "."]
          ]
        }
      },
      {
        type = "metric", x = 12, y = 6, width = 12, height = 6
        properties = {
          title  = "DynamoDB — throttled requests"
          region = var.region
          view   = "timeSeries"
          stat   = "Sum"
          period = 300
          metrics = [
            ["AWS/DynamoDB", "ThrottledRequests", "TableName", var.table_name],
            [".", "UserErrors", ".", "."]
          ]
        }
      },
      {
        type = "log", x = 0, y = 12, width = 24, height = 6
        properties = {
          title  = "API — recent errors"
          region = var.region
          # Lambda writes uncaught errors and our own console.error here.
          query = "SOURCE '${var.log_group}' | fields @timestamp, @message | filter @message like /error/ | sort @timestamp desc | limit 50"
          view  = "table"
        }
      }
    ]
  })
}
