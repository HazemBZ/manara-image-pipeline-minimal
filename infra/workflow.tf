resource "aws_cloudwatch_log_group" "workflow" {
  name              = "/aws/vendedlogs/states/${local.name}"
  retention_in_days = 14
}

resource "aws_iam_role" "workflow" {
  name = "${local.name}-workflow"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow", Principal = { Service = "states.amazonaws.com" }, Action = "sts:AssumeRole"
      Condition = {
        StringEquals = { "aws:SourceAccount" = local.account }
        ArnEquals    = { "aws:SourceArn" = local.state_arn }
      }
    }]
  })
}

resource "aws_iam_role_policy" "workflow" {
  role = aws_iam_role.workflow.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      {
        Effect   = "Allow"
        Action   = ["lambda:InvokeFunction"]
        Resource = [for key in ["validate", "resize", "watermark", "store", "fail"] : local.lambda_arns[key]]
      },
      {
        Effect = "Allow"
        # These log-delivery APIs do not support resource-level permissions.
        Action = ["logs:CreateLogDelivery", "logs:GetLogDelivery", "logs:UpdateLogDelivery",
          "logs:DeleteLogDelivery", "logs:ListLogDeliveries", "logs:PutResourcePolicy",
        "logs:DescribeResourcePolicies", "logs:DescribeLogGroups"]
        Resource = "*"
      }
    ], local.notify)
  })
}

locals {
  processing_steps = ["validate", "resize", "watermark", "store"]
  processing_states = {
    for index, task in local.processing_steps : title(task) => {
      Type           = "Task"
      Resource       = "${local.prefix}:states:::lambda:invoke"
      Parameters     = { FunctionName = local.lambda_arns[task], "Payload.$" = "$" }
      OutputPath     = "$.Payload"
      TimeoutSeconds = 90
      Retry = [{
        ErrorEquals     = ["Lambda.ServiceException", "Lambda.AWSLambdaException", "Lambda.SdkClientException", "Lambda.TooManyRequestsException"]
        IntervalSeconds = 2, MaxAttempts = 3, BackoffRate = 2, JitterStrategy = "FULL"
      }]
      Catch = [{ ErrorEquals = ["States.ALL"], ResultPath = "$.failure", Next = "MarkFailed" }]
      Next  = index == 3 ? "NotifySuccess" : title(local.processing_steps[index + 1])
    }
  }
}

resource "aws_sfn_state_machine" "pipeline" {
  name     = local.name
  role_arn = aws_iam_role.workflow.arn
  type     = "STANDARD"
  logging_configuration {
    log_destination        = "${aws_cloudwatch_log_group.workflow.arn}:*"
    include_execution_data = false
    level                  = "ERROR"
  }
  definition = jsonencode({
    Comment        = "Version-pinned image pipeline. Only S3 references enter state payloads."
    StartAt        = "Validate"
    TimeoutSeconds = 600
    States = merge(local.processing_states, {
      NotifySuccess = {
        Type = "Task", Resource = "${local.prefix}:states:::sns:publish"
        Parameters = {
          TopicArn = local.topic_arn, Subject = "Image processing completed"
          Message  = { "job_id.$" = "$.job_id", status = "COMPLETED" }
        }
        ResultPath = null
        Retry      = [{ ErrorEquals = ["States.TaskFailed"], IntervalSeconds = 2, MaxAttempts = 3, BackoffRate = 2 }]
        # Keep completed image jobs completed; a notification failure is an execution alarm.
        Catch = [{ ErrorEquals = ["States.ALL"], ResultPath = "$.notification_failure", Next = "NotificationFailed" }]
        Next  = "Done"
      }
      MarkFailed = {
        Type       = "Task", Resource = "${local.prefix}:states:::lambda:invoke"
        Parameters = { FunctionName = local.lambda_arns["fail"], "Payload.$" = "$" }
        OutputPath = "$.Payload"
        Retry      = [{ ErrorEquals = ["States.TaskFailed"], IntervalSeconds = 2, MaxAttempts = 3, BackoffRate = 2 }]
        Catch      = [{ ErrorEquals = ["States.ALL"], ResultPath = "$.failure_handler_error", Next = "Failed" }]
        Next       = "NotifyFailure"
      }
      NotifyFailure = {
        Type = "Task", Resource = "${local.prefix}:states:::sns:publish"
        Parameters = {
          TopicArn = local.topic_arn, Subject = "Image processing failed"
          Message  = { "job_id.$" = "$.job_id", status = "FAILED" }
        }
        Retry = [{ ErrorEquals = ["States.TaskFailed"], IntervalSeconds = 2, MaxAttempts = 3, BackoffRate = 2 }]
        Catch = [{ ErrorEquals = ["States.ALL"], ResultPath = "$.notification_failure", Next = "Failed" }]
        Next  = "Failed"
      }
      Done               = { Type = "Succeed" }
      Failed             = { Type = "Fail", Error = "ImageProcessingFailed", Cause = "Inspect task logs for the job ID." }
      NotificationFailed = { Type = "Fail", Error = "NotificationFailed", Cause = "Images are complete, but SNS delivery failed." }
    })
  })
  depends_on = [aws_iam_role_policy.workflow, aws_lambda_function.functions]
}

resource "aws_cloudwatch_event_rule" "recovery" {
  name = "${local.name}-recovery"
  event_pattern = jsonencode({
    source        = ["aws.states"]
    "detail-type" = ["Step Functions Execution Status Change"]
    detail = {
      stateMachineArn = [local.state_arn]
      status          = ["FAILED", "TIMED_OUT", "ABORTED"]
    }
  })
}

resource "aws_cloudwatch_event_target" "recovery" {
  rule = aws_cloudwatch_event_rule.recovery.name
  arn  = aws_lambda_function.functions["fail"].arn
}

resource "aws_lambda_permission" "recovery" {
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.functions["fail"].function_name
  principal      = "events.amazonaws.com"
  source_arn     = aws_cloudwatch_event_rule.recovery.arn
  source_account = local.account
}
