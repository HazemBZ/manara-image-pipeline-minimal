locals {
  function_settings = {
    authorizer = { handler = "pipeline.authorizer.handler", memory = 128, timeout = 5 }
    api        = { handler = "pipeline.api.handler", memory = 256, timeout = 15 }
    dispatcher = { handler = "pipeline.dispatcher.handler", memory = 256, timeout = 30 }
    validate   = { handler = "pipeline.worker.handler", memory = 1024, timeout = 60 }
    resize     = { handler = "pipeline.worker.handler", memory = 1024, timeout = 60 }
    watermark  = { handler = "pipeline.worker.handler", memory = 512, timeout = 60 }
    store      = { handler = "pipeline.worker.handler", memory = 256, timeout = 30 }
    fail       = { handler = "pipeline.worker.handler", memory = 256, timeout = 30 }
  }
  table_read = {
    Effect = "Allow", Action = ["dynamodb:GetItem"], Resource = aws_dynamodb_table.jobs.arn
  }
  table_update = {
    Effect = "Allow", Action = ["dynamodb:UpdateItem"], Resource = aws_dynamodb_table.jobs.arn
  }
  source_read = {
    Effect = "Allow", Action = ["s3:GetObjectVersion"], Resource = "${aws_s3_bucket.buckets["source"].arn}/uploads/*"
  }
  internal_read = {
    Effect = "Allow", Action = ["s3:GetObject"], Resource = "${aws_s3_bucket.buckets["processed"].arn}/internal/*"
  }
  internal_write = {
    Effect = "Allow", Action = ["s3:PutObject"], Resource = "${aws_s3_bucket.buckets["processed"].arn}/internal/*"
  }
  notify = [
    { Effect = "Allow", Action = ["sns:Publish"], Resource = aws_sns_topic.jobs.arn },
    { Effect = "Allow", Action = ["kms:Decrypt", "kms:GenerateDataKey"], Resource = aws_kms_key.notifications.arn }
  ]
  task_permissions = {
    authorizer = []
    api = [local.table_read,
      { Effect = "Allow", Action = ["dynamodb:PutItem"], Resource = aws_dynamodb_table.jobs.arn },
      { Effect = "Allow", Action = ["s3:PutObject"], Resource = "${aws_s3_bucket.buckets["source"].arn}/uploads/*" }
    ]
    dispatcher = [local.table_read, local.table_update,
      { Effect = "Allow", Action = ["states:StartExecution"], Resource = local.state_arn },
      { Effect = "Allow", Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"], Resource = aws_sqs_queue.uploads.arn }
    ]
    validate  = [local.table_read, local.table_update, local.source_read]
    resize    = [local.source_read, local.internal_write]
    watermark = [local.internal_read, local.internal_write]
    store = [local.internal_read, local.table_update,
      { Effect = "Allow", Action = ["s3:PutObject"], Resource = "${aws_s3_bucket.buckets["processed"].arn}/images/*" }
    ]
    fail = concat([local.table_update], local.notify)
  }
}

resource "aws_cloudwatch_log_group" "functions" {
  for_each          = local.function_settings
  name              = "/aws/lambda/${local.name}-${each.key}"
  retention_in_days = 14
}

resource "aws_iam_role" "functions" {
  for_each = local.function_settings
  name     = "${local.name}-${each.key}"
  # Lambda execution-role assumptions do not supply SourceArn/SourceAccount.
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow", Principal = { Service = "lambda.amazonaws.com" }, Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "functions" {
  for_each = local.function_settings
  role     = aws_iam_role.functions[each.key].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.functions[each.key].arn}:*"
      }
    ], local.task_permissions[each.key])
  })
}

resource "aws_lambda_layer_version" "dependencies" {
  layer_name               = "${local.name}-dependencies"
  filename                 = "${path.module}/../build/layer.zip"
  source_code_hash         = filebase64sha256("${path.module}/../build/layer.zip")
  compatible_runtimes      = ["python3.13"]
  compatible_architectures = ["x86_64"]
}

resource "aws_lambda_function" "functions" {
  for_each         = local.function_settings
  function_name    = "${local.name}-${each.key}"
  role             = aws_iam_role.functions[each.key].arn
  handler          = each.value.handler
  runtime          = "python3.13"
  architectures    = ["x86_64"]
  memory_size      = each.value.memory
  timeout          = each.value.timeout
  filename         = "${path.module}/../build/handlers.zip"
  source_code_hash = filebase64sha256("${path.module}/../build/handlers.zip")
  layers           = each.key == "authorizer" ? [] : [aws_lambda_layer_version.dependencies.arn]
  environment {
    variables = merge(
      {
        TABLE_NAME         = aws_dynamodb_table.jobs.name
        SOURCE_BUCKET      = aws_s3_bucket.buckets["source"].id
        DESTINATION_BUCKET = aws_s3_bucket.buckets["processed"].id
        STATE_MACHINE_ARN  = local.state_arn
        TOPIC_ARN          = aws_sns_topic.jobs.arn
        TASK_ACTION        = each.key
        WATERMARK_TEXT     = var.watermark_text
      },
      each.key == "authorizer" ? { TOKEN_SHA256 = var.token_sha256 } : {},
      each.key == "api" ? { CDN_URL = "https://${aws_cloudfront_distribution.app.domain_name}" } : {}
    )
  }
  depends_on = [aws_iam_role_policy.functions]
}

resource "aws_lambda_event_source_mapping" "uploads" {
  event_source_arn        = aws_sqs_queue.uploads.arn
  function_name           = aws_lambda_function.functions["dispatcher"].arn
  batch_size              = 5
  function_response_types = ["ReportBatchItemFailures"]
  scaling_config { maximum_concurrency = 2 }
}
