terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.9"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# -----------------------------------------------------------------------------
# ECR Repository for Custom Container
# -----------------------------------------------------------------------------

resource "aws_ecr_repository" "apertus_inference" {
  name                 = "${var.project_name}-inference"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

# IAM Role for SageMaker
resource "aws_iam_role" "sagemaker_role" {
  name = "${var.project_name}-sagemaker-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "sagemaker.amazonaws.com"
      }
    }]
  })
}

# Least-privilege inline policy for SageMaker execution role
resource "aws_iam_role_policy" "sagemaker_execution" {
  name = "${var.project_name}-sagemaker-execution-policy"
  role = aws_iam_role.sagemaker_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ECRPullImage"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage"
        ]
        Resource = [aws_ecr_repository.apertus_inference.arn]
      },
      {
        Sid      = "ECRAuth"
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogStreams"
        ]
        Resource = "arn:aws:logs:${var.aws_region}:*:log-group:/aws/sagemaker/*"
      }
    ]
  })
}

# Wait for IAM role propagation
resource "time_sleep" "iam_propagation" {
  depends_on      = [aws_iam_role_policy.sagemaker_execution]
  create_duration = "30s"
}

# SageMaker Model
resource "aws_sagemaker_model" "apertus" {
  name               = "${var.project_name}-apertus-70b"
  execution_role_arn = aws_iam_role.sagemaker_role.arn
  depends_on         = [time_sleep.iam_propagation]

  primary_container {
    image = "${aws_ecr_repository.apertus_inference.repository_url}:${var.image_tag}"
    environment = {
      HF_MODEL_ID = "swiss-ai/Apertus-70B-Instruct-2509"
      AWS_REGION  = var.aws_region
      SM_NUM_GPUS = "8"
    }
  }
}

# The endpoint is intentionally ephemeral: created/deleted by the Lambda functions.
# Terraform manages the endpoint configuration but NOT the endpoint itself.
# BOOTSTRAP: After first `terraform apply`, create the endpoint by invoking:
#   aws lambda invoke --function-name apertus-llm-start-endpoint --payload '{}' /dev/stdout
locals {
  endpoint_name        = "${var.project_name}-apertus-endpoint"
  endpoint_config_name = aws_sagemaker_endpoint_configuration.apertus.name
}

# SageMaker Endpoint Configuration
resource "aws_sagemaker_endpoint_configuration" "apertus" {
  name = "${var.project_name}-apertus-config"

  production_variants {
    variant_name                                      = "primary"
    model_name                                        = aws_sagemaker_model.apertus.name
    initial_instance_count                            = 1
    instance_type                                     = var.instance_type
    container_startup_health_check_timeout_in_seconds = 900
  }
}

# Outputs
output "endpoint_name" {
  description = "SageMaker endpoint name (lifecycle managed by Lambda, not Terraform)"
  value       = local.endpoint_name
}

output "ecr_repository_url" {
  description = "ECR repository URL for the custom inference image"
  value       = aws_ecr_repository.apertus_inference.repository_url
}
