# =============================================================================
# SageMaker Endpoint Lifecycle Management
# Lambda functions for starting/stopping the endpoint (always deployed).
# EventBridge cron scheduling is optional (controlled by enable_endpoint_scheduler).
# =============================================================================

# -----------------------------------------------------------------------------
# Data Sources
# -----------------------------------------------------------------------------

data "aws_caller_identity" "current" {}

data "archive_file" "stop_endpoint" {
  type        = "zip"
  source_file = "${path.module}/lambda/stop_endpoint.py"
  output_path = "${path.module}/lambda/stop_endpoint.zip"
}

data "archive_file" "start_endpoint" {
  type        = "zip"
  source_file = "${path.module}/lambda/start_endpoint.py"
  output_path = "${path.module}/lambda/start_endpoint.zip"
}

# -----------------------------------------------------------------------------
# IAM Role for Lambda
# -----------------------------------------------------------------------------

resource "aws_iam_role" "endpoint_scheduler" {
  name = "${var.project_name}-endpoint-scheduler-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy" "endpoint_scheduler" {
  name = "${var.project_name}-endpoint-scheduler-policy"
  role = aws_iam_role.endpoint_scheduler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SageMakerEndpointManagement"
        Effect = "Allow"
        Action = [
          "sagemaker:CreateEndpoint",
          "sagemaker:DeleteEndpoint",
          "sagemaker:DescribeEndpoint",
          "sagemaker:DescribeEndpointConfig"
        ]
        Resource = [
          "arn:aws:sagemaker:${var.aws_region}:${data.aws_caller_identity.current.account_id}:endpoint/${var.project_name}-*",
          "arn:aws:sagemaker:${var.aws_region}:${data.aws_caller_identity.current.account_id}:endpoint-config/${var.project_name}-*"
        ]
      },
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${var.project_name}-*"
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# CloudWatch Log Groups
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "stop_endpoint" {
  name              = "/aws/lambda/${var.project_name}-stop-endpoint"
  retention_in_days = 14
}

resource "aws_cloudwatch_log_group" "start_endpoint" {
  name              = "/aws/lambda/${var.project_name}-start-endpoint"
  retention_in_days = 14
}

# -----------------------------------------------------------------------------
# Lambda Functions
# -----------------------------------------------------------------------------

resource "aws_lambda_function" "stop_endpoint" {
  function_name = "${var.project_name}-stop-endpoint"
  description   = "Stops (deletes) the SageMaker embedding endpoint to save costs"
  role          = aws_iam_role.endpoint_scheduler.arn
  handler       = "stop_endpoint.lambda_handler"
  runtime       = var.lambda_runtime
  timeout       = 30
  memory_size   = 128

  filename         = data.archive_file.stop_endpoint.output_path
  source_code_hash = data.archive_file.stop_endpoint.output_base64sha256

  environment {
    variables = {
      ENDPOINT_NAME = local.endpoint_name
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.stop_endpoint,
    aws_iam_role_policy.endpoint_scheduler
  ]
}

resource "aws_lambda_function" "start_endpoint" {
  function_name = "${var.project_name}-start-endpoint"
  description   = "Starts (creates) the SageMaker embedding endpoint using existing config"
  role          = aws_iam_role.endpoint_scheduler.arn
  handler       = "start_endpoint.lambda_handler"
  runtime       = var.lambda_runtime
  timeout       = 30
  memory_size   = 128

  filename         = data.archive_file.start_endpoint.output_path
  source_code_hash = data.archive_file.start_endpoint.output_base64sha256

  environment {
    variables = {
      ENDPOINT_NAME        = local.endpoint_name
      ENDPOINT_CONFIG_NAME = local.endpoint_config_name
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.start_endpoint,
    aws_iam_role_policy.endpoint_scheduler
  ]
}

# -----------------------------------------------------------------------------
# EventBridge Schedules
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_event_rule" "stop_endpoint" {
  count               = var.enable_endpoint_scheduler ? 1 : 0
  name                = "${var.project_name}-stop-endpoint-schedule"
  description         = "Triggers Lambda to stop SageMaker embedding endpoint outside business hours"
  schedule_expression = var.endpoint_stop_schedule
}

resource "aws_cloudwatch_event_rule" "start_endpoint" {
  count               = var.enable_endpoint_scheduler ? 1 : 0
  name                = "${var.project_name}-start-endpoint-schedule"
  description         = "Triggers Lambda to start SageMaker embedding endpoint during business hours"
  schedule_expression = var.endpoint_start_schedule
}

resource "aws_cloudwatch_event_target" "stop_endpoint" {
  count     = var.enable_endpoint_scheduler ? 1 : 0
  rule      = aws_cloudwatch_event_rule.stop_endpoint[0].name
  target_id = "StopEndpointLambda"
  arn       = aws_lambda_function.stop_endpoint.arn
}

resource "aws_cloudwatch_event_target" "start_endpoint" {
  count     = var.enable_endpoint_scheduler ? 1 : 0
  rule      = aws_cloudwatch_event_rule.start_endpoint[0].name
  target_id = "StartEndpointLambda"
  arn       = aws_lambda_function.start_endpoint.arn
}

resource "aws_lambda_permission" "stop_endpoint" {
  count         = var.enable_endpoint_scheduler ? 1 : 0
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.stop_endpoint.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.stop_endpoint[0].arn
}

resource "aws_lambda_permission" "start_endpoint" {
  count         = var.enable_endpoint_scheduler ? 1 : 0
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.start_endpoint.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.start_endpoint[0].arn
}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------

output "stop_endpoint_lambda_arn" {
  description = "ARN of the stop endpoint Lambda function"
  value       = aws_lambda_function.stop_endpoint.arn
}

output "start_endpoint_lambda_arn" {
  description = "ARN of the start endpoint Lambda function"
  value       = aws_lambda_function.start_endpoint.arn
}

output "endpoint_stop_schedule" {
  description = "Cron schedule for stopping the endpoint"
  value       = var.enable_endpoint_scheduler ? var.endpoint_stop_schedule : null
}

output "endpoint_start_schedule" {
  description = "Cron schedule for starting the endpoint"
  value       = var.enable_endpoint_scheduler ? var.endpoint_start_schedule : null
}
