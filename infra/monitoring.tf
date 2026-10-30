locals {
  alarms = {
    dlq = {
      namespace  = "AWS/SQS", metric = "ApproximateNumberOfMessagesVisible", statistic = "Maximum"
      dimensions = { QueueName = aws_sqs_queue.dlq.name }, threshold = 1
    }
    backlog = {
      namespace  = "AWS/SQS", metric = "ApproximateAgeOfOldestMessage", statistic = "Maximum"
      dimensions = { QueueName = aws_sqs_queue.uploads.name }, threshold = 300
    }
    workflow = {
      namespace  = "AWS/States", metric = "ExecutionsFailed", statistic = "Sum"
      dimensions = { StateMachineArn = local.state_arn }, threshold = 1
    }
    timeouts = {
      namespace  = "AWS/States", metric = "ExecutionsTimedOut", statistic = "Sum"
      dimensions = { StateMachineArn = local.state_arn }, threshold = 1
    }
    api = {
      namespace  = "AWS/ApiGateway", metric = "5xx", statistic = "Sum"
      dimensions = { ApiId = aws_apigatewayv2_api.app.id }, threshold = 1
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "pipeline" {
  for_each            = local.alarms
  alarm_name          = "${local.name}-${each.key}"
  alarm_description   = "See docs/runbook.md. Project ${local.name}."
  namespace           = each.value.namespace
  metric_name         = each.value.metric
  statistic           = each.value.statistic
  dimensions          = each.value.dimensions
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = each.value.threshold
  evaluation_periods  = 1
  period              = 300
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.jobs.arn]
}

resource "aws_cloudwatch_metric_alarm" "lambda" {
  for_each            = local.function_settings
  alarm_name          = "${local.name}-${each.key}-errors"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  statistic           = "Sum"
  dimensions          = { FunctionName = aws_lambda_function.functions[each.key].function_name }
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  evaluation_periods  = 1
  period              = 300
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.jobs.arn]
}
