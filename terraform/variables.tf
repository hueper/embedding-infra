variable "aws_region" {
  description = "AWS region for deployment"
  default     = "eu-central-1"
}

variable "project_name" {
  description = "Project name prefix for resources"
  default     = "embedding"
}

variable "instance_type" {
  description = "SageMaker instance type"
  default     = "ml.g5.xlarge"
}

variable "image_tag" {
  description = "Container image tag (set to Git SHA by CI)"
  type        = string
}

variable "github_repo" {
  description = "GitHub repository (org/repo) for OIDC trust policy"
  type        = string
}

variable "create_github_oidc_provider" {
  description = "Create the GitHub Actions OIDC provider. Set to false if it already exists in this account (e.g. created by another infra module)."
  type        = bool
  default     = false
}

# Endpoint Scheduler Variables
variable "enable_endpoint_scheduler" {
  description = "Enable EventBridge cron scheduling for automatic endpoint start/stop. Lambda functions are always deployed regardless of this setting."
  type        = bool
  default     = false
}

variable "endpoint_start_schedule" {
  description = "Cron expression for starting the endpoint (UTC timezone)"
  type        = string
  default     = "cron(0 7 ? * MON-FRI *)" # 7:00 AM UTC Mon-Fri
}

variable "endpoint_stop_schedule" {
  description = "Cron expression for stopping the endpoint (UTC timezone)"
  type        = string
  default     = "cron(0 18 ? * MON-FRI *)" # 6:00 PM UTC Mon-Fri
}

variable "lambda_runtime" {
  description = "Python runtime version for Lambda functions"
  type        = string
  default     = "python3.12"
}
