# =============================================================================
# GitHub Actions CI — OIDC provider + IAM role for ECR image push
# =============================================================================

# The GitHub OIDC provider is a global IAM resource (one per AWS account).
# If another infra module (e.g. apertus-70b-infra) already created it,
# set create_github_oidc_provider = false and this module will look it up instead.

data "aws_iam_openid_connect_provider" "github_existing" {
  count = var.create_github_oidc_provider ? 0 : 1
  url   = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_openid_connect_provider" "github_new" {
  count          = var.create_github_oidc_provider ? 1 : 0
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]

  # Root CA thumbprint for GitHub Actions OIDC (DigiCert Global Root G2).
  # Source: https://github.blog/changelog/2023-06-27-github-actions-update-on-oidc-integration-with-aws/
  thumbprint_list = ["1c58a3a8518e8759bf075b76b750d4f2df264fcd"]
}

locals {
  github_oidc_provider_arn = var.create_github_oidc_provider ? aws_iam_openid_connect_provider.github_new[0].arn : data.aws_iam_openid_connect_provider.github_existing[0].arn
}

# IAM role for GitHub Actions — can only push to this project's ECR repo
resource "aws_iam_role" "github_actions" {
  name = "${var.project_name}-github-actions"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = local.github_oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          # Scoped to the main branch only — prevents PRs or other branches from assuming this role
          "token.actions.githubusercontent.com:sub" = "repo:${var.github_repo}:ref:refs/heads/main"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "github_actions_ecr" {
  name = "${var.project_name}-github-actions-ecr"
  role = aws_iam_role.github_actions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ECRAuth"
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      {
        Sid    = "ECRPush"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:PutImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload"
        ]
        Resource = aws_ecr_repository.embedding_inference.arn
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------

output "github_actions_role_arn" {
  description = "IAM role ARN for GitHub Actions OIDC"
  value       = aws_iam_role.github_actions.arn
}
