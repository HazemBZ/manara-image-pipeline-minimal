resource "aws_apigatewayv2_api" "app" {
  name          = local.name
  protocol_type = "HTTP"
  cors_configuration {
    allow_origins = ["https://${aws_cloudfront_distribution.app.domain_name}"]
    allow_methods = ["POST", "GET", "OPTIONS"]
    allow_headers = ["Authorization", "Content-Type"]
    max_age       = 300
  }
}

resource "aws_apigatewayv2_authorizer" "token" {
  api_id                            = aws_apigatewayv2_api.app.id
  name                              = "demo-token"
  authorizer_type                   = "REQUEST"
  authorizer_uri                    = aws_lambda_function.functions["authorizer"].invoke_arn
  authorizer_payload_format_version = "2.0"
  enable_simple_responses           = true
  identity_sources                  = ["$request.header.Authorization"]
  authorizer_result_ttl_in_seconds  = 0
}

resource "aws_apigatewayv2_integration" "api" {
  api_id                 = aws_apigatewayv2_api.app.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.functions["api"].invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "api" {
  for_each           = toset(["POST /uploads", "GET /jobs/{job_id}"])
  api_id             = aws_apigatewayv2_api.app.id
  route_key          = each.value
  target             = "integrations/${aws_apigatewayv2_integration.api.id}"
  authorization_type = "CUSTOM"
  authorizer_id      = aws_apigatewayv2_authorizer.token.id
}

resource "aws_cloudwatch_log_group" "api" {
  name              = "/aws/apigateway/${local.name}"
  retention_in_days = 14
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.app.id
  name        = "$default"
  auto_deploy = true
  default_route_settings {
    throttling_burst_limit = 5
    throttling_rate_limit  = 2
  }
  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api.arn
    format = jsonencode({
      requestId        = "$context.requestId", routeKey = "$context.routeKey", status = "$context.status"
      integrationError = "$context.integrationErrorMessage"
    })
  }
}

resource "aws_lambda_permission" "api" {
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.functions["api"].function_name
  principal      = "apigateway.amazonaws.com"
  source_arn     = "${aws_apigatewayv2_api.app.execution_arn}/*/*"
  source_account = local.account
}

resource "aws_lambda_permission" "authorizer" {
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.functions["authorizer"].function_name
  principal      = "apigateway.amazonaws.com"
  source_arn     = "${aws_apigatewayv2_api.app.execution_arn}/authorizers/${aws_apigatewayv2_authorizer.token.id}"
  source_account = local.account
}
