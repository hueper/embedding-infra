# Infrastructure — Apertus-70B on SageMaker

Terraform configuration for deploying the [Apertus-70B-Instruct-2509](https://huggingface.co/swiss-ai/Apertus-70B-Instruct-2509) model on AWS SageMaker with automated cost scheduling.

## Architecture

```
SageMaker Endpoint (ml.g5.48xlarge) ← Endpoint Config ← Model ← Custom vLLM container (ECR)

Lambda lifecycle (always deployed)
  start: aws lambda invoke --function-name apertus-llm-start-endpoint
  stop:  aws lambda invoke --function-name apertus-llm-stop-endpoint

EventBridge scheduling (optional, enable_endpoint_scheduler=true)
  start: 7 AM UTC Mon–Fri    stop: 6 PM UTC Mon–Fri

GitHub Actions (OIDC) → builds and pushes container image to ECR on merge to main
```

The SageMaker endpoint is **ephemeral** — created and deleted by the Lambda functions to avoid idle costs (~$16.29/hr). It is not tracked in Terraform state. The start/stop Lambdas are always deployed for manual invocation; EventBridge cron scheduling is an optional layer controlled by `enable_endpoint_scheduler`. Everything else (model, endpoint config, ECR, IAM, Lambdas) is long-lived and Terraform-managed.

The model is open-weight (Apache 2.0) — no HuggingFace token required.

Container images are built by CI using `vllm/vllm-openai:v0.11.0` as base and tagged with the Git SHA. Local Docker builds are not required.

## CI Build Environment

The container image is large (~30–40 GB unpacked).
Building it on GitHub-hosted runners may fail due to disk limits.

In production, this repository is built using a **self-hosted GitHub Actions runner**
(EC2 with large disk, long-lived CI infrastructure).

If you encounter `no space left on device` errors in CI, switch the workflow to a
self-hosted runner.

## Prerequisites

- AWS CLI configured with appropriate credentials
- Terraform >= 1.0

## Deploy

```bash
cd terraform

# 1. Provision base infrastructure (creates ECR, OIDC provider, CI role)
terraform init
terraform apply \
  -target=aws_ecr_repository.apertus_inference \
  -target=aws_iam_openid_connect_provider.github \
  -target=aws_iam_role.github_actions \
  -target=aws_iam_role_policy.github_actions_ecr

# 2. Set AWS_ROLE_ARN secret in GitHub repo settings
#    (value from: terraform output github_actions_role_arn)

# 3. Push to main (or trigger workflow manually) to build the image

# 4. Provision remaining infrastructure with the image tag from CI
terraform apply -var="image_tag=<git-sha>"
# Optionally enable EventBridge scheduling (auto start/stop Mon–Fri):
# terraform apply -var="image_tag=<git-sha>" -var="enable_endpoint_scheduler=true"

# 5. Start the endpoint
aws lambda invoke --function-name apertus-llm-start-endpoint --payload '{}' response.json
# (if enable_endpoint_scheduler=true, EventBridge will handle subsequent start/stop automatically)
```

> **Note:** The `-target` apply in step 1 is a one-time bootstrap to break the circular dependency (CI needs ECR + OIDC role to push, Terraform needs an image tag to create the model). After the first image is pushed, all subsequent deploys use a normal `terraform apply`.

The endpoint takes ~10–15 minutes to reach `InService`.

## Structure

```
infra/
├── .github/workflows/
│   └── build-image.yml  CI: build and push container image to ECR
├── terraform/
│   ├── main.tf          Model, endpoint config, ECR, IAM
│   ├── lambda.tf        Endpoint lifecycle (Lambda always-on + optional EventBridge)
│   ├── ci.tf            GitHub OIDC provider + CI IAM role
│   ├── variables.tf
│   ├── container/       Dockerfile + entrypoint (vLLM) + SageMaker adapter
│   └── lambda/          Start/stop Lambda handlers
```

## Full Shutdown / Destroy

To permanently shut down the system and ensure the endpoint cannot be recreated:

```bash
cd terraform

# 1. Disable automatic scheduling (removes EventBridge rules; Lambdas remain for manual use)
terraform apply -var="enable_endpoint_scheduler=false"

# 2. Delete the endpoint (if running)
aws sagemaker delete-endpoint --endpoint-name apertus-llm-apertus-endpoint

# 3. Destroy all remaining Terraform-managed resources
terraform destroy
```

## Configuration

| Variable | Default | Description |
|---|---|---|
| `image_tag` | *(required)* | Container image tag (Git SHA from CI) |
| `github_repo` | *(required)* | GitHub repository (org/repo) for OIDC trust |
| `aws_region` | `us-east-1` | AWS region |
| `instance_type` | `ml.g5.48xlarge` | SageMaker GPU instance (8× A10G) |
| `enable_endpoint_scheduler` | `false` | EventBridge cron scheduling (Lambdas always deployed) |
| `endpoint_start_schedule` | `cron(0 7 ? * MON-FRI *)` | Start time (UTC) |
| `endpoint_stop_schedule` | `cron(0 18 ? * MON-FRI *)` | Stop time (UTC) |
