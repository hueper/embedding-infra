# embedding-infra

SageMaker inference endpoint for `intfloat/multilingual-e5-large` — converts text into dense vectors for semantic similarity search.

| | |
|---|---|
| **Model** | `intfloat/multilingual-e5-large` (560M params, 1024-dim, Apache 2.0) |
| **Instance** | `ml.g5.xlarge` (24 GB GPU, ~$1.10/hr in eu-central-1) |
| **Region** | `eu-central-1` |
| **Endpoint lifecycle** | Ephemeral — created/deleted by Lambda; Terraform manages config only |

## Architecture

Follows the same pattern as `apertus-70b-infra/`:

```
ECR image → SageMaker Model → Endpoint Config
                                    ↓
                          Lambda start/stop (always deployed)
                                    ↓
                          EventBridge scheduler (optional, weekday 7–18 UTC)
```

## Prerequisites

1. The GitHub Actions OIDC provider must exist in this AWS account. It was likely already created by `apertus-70b-infra`. If not, set `create_github_oidc_provider = true` in your tfvars.
2. Add `EMBEDDING_AWS_ROLE_ARN` as a GitHub Actions secret (output from `terraform apply`).

---

## Deployment

### 0. First-time bootstrap

The ECR repository must exist before CI can push to it, but Terraform needs an `image_tag` to create the SageMaker model. On first deploy:

```bash
# 1. Create ECR repo and all other resources with a placeholder image tag
cd embedding-infra/terraform
terraform init
terraform apply \
  -var="image_tag=placeholder" \
  -var="github_repo=<org>/<repo>"

# 2. Add the role ARN output as a GitHub Actions secret
terraform output github_actions_role_arn
# → add as EMBEDDING_AWS_ROLE_ARN in GitHub repo settings

# 3. Push to GitHub and trigger the workflow (or run manually)
gh workflow run build-image.yml -R <org>/<repo>

# 4. Once the workflow completes, re-apply with the real image tag
terraform apply \
  -var="image_tag=<git-sha-from-step-3>" \
  -var="github_repo=<org>/<repo>"
```

After this, subsequent deploys only need steps 3 and 4 (push → apply → cycle endpoint).

---

### 1. Build and push the container image

The image (~3 GB) bakes in the model weights at build time. Trigger via GitHub Actions push to main, or manually (same command as bootstrap step 3).

### 2. Apply Terraform

Same as bootstrap step 4, substituting the real image tag from CI.

### 3. Start the endpoint

The endpoint is not created by Terraform. Start it manually after the first apply:

```bash
aws lambda invoke \
  --function-name embedding-start-endpoint \
  --region eu-central-1 \
  --payload '{}' \
  /dev/stdout
```

Wait ~8 minutes for `InService` status:
```bash
aws sagemaker describe-endpoint \
  --endpoint-name embedding-embedding-endpoint \
  --region eu-central-1 \
  --query 'EndpointStatus'
```

### 4. Validate — functional + GPU check

**Functional check** (embedding shape and normalization):
```bash
aws sagemaker-runtime invoke-endpoint \
  --endpoint-name embedding-embedding-endpoint \
  --content-type application/json \
  --region eu-central-1 \
  --body '{"texts":["passage: This is a test sentence."],"batch_size":1}' \
  /tmp/embedding_out.json && python3 -c "
import json
r = json.load(open('/tmp/embedding_out.json'))
emb = r['embeddings'][0]
print(f'dim={len(emb)}, first3={emb[:3]}, norm={sum(x**2 for x in emb)**0.5:.4f}')
"
# Expected: dim=1024, norm≈1.0 (L2-normalized vectors)
```

**GPU check** — run this inside the container or via SageMaker exec to confirm the model is not silently running on CPU:
```bash
# From inside the container (docker run or SageMaker exec):
python3.11 -c "
import torch
from sentence_transformers import SentenceTransformer
m = SentenceTransformer('intfloat/multilingual-e5-large')
device = next(m.parameters()).device
print(f'Model device: {device}')
assert str(device) != 'cpu', 'ERROR: model is on CPU, not GPU'
print('GPU confirmed')
"
# Expected: Model device: cuda:0
```

If the model lands on CPU, the container starts and `/ping` returns healthy, but embedding throughput will be ~10–20x slower and the endpoint will timeout on large batches. Fix: verify the CUDA base image version matches the SageMaker instance's CUDA driver version (ml.g5.xlarge ships with CUDA 12.x drivers — if there's a mismatch, upgrade the base image to `nvidia/cuda:12.1.0-cudnn8-runtime-ubuntu22.04` and torch to `torch==2.2.0`).

---

## ⚠️ Deploying a new image version

`terraform apply` creates a new SageMaker Model + Endpoint Config but does **not** update a running endpoint. After every image push + `terraform apply`:

```
terraform apply → green ✓  ← does NOT mean the new image is live
```

**You must cycle the endpoint manually:**
```bash
# 1. Stop (delete) the running endpoint
aws lambda invoke \
  --function-name embedding-stop-endpoint \
  --region eu-central-1 \
  --payload '{}' /dev/stdout

# 2. Wait for deletion (~30s), then start with the new config
aws lambda invoke \
  --function-name embedding-start-endpoint \
  --region eu-central-1 \
  --payload '{}' /dev/stdout

# 3. Confirm the new image tag is live
aws sagemaker describe-endpoint \
  --endpoint-name embedding-embedding-endpoint \
  --region eu-central-1 \
  --query 'ProductionVariants[0].CurrentInstanceCount'
```

This is intentional — the endpoint is ephemeral and Terraform deliberately does not manage it to avoid accidental mid-traffic recreation.

---

## Endpoint state contract for callers

Expected behaviour per endpoint state:

| `describe_endpoint` result | Caller behaviour |
|---|---|
| `InService` | Proceed with embedding calls |
| `Creating` or `Updating` | Poll every 30s, up to 15 min, then fail job |
| `Failed` | Fail job immediately: `"Embedding endpoint in Failed state"` |
| `Deleting` | Fail job immediately: `"Embedding endpoint is being deleted"` |
| `ValidationException` (not found) | Fail job immediately: `"Embedding endpoint is stopped — invoke embedding-start-endpoint Lambda"` |

Callers do **not** trigger the start Lambda. Starting the endpoint is an operator action.

---

## Cost management

- Stop the endpoint when not in use:
  ```bash
  aws lambda invoke --function-name embedding-stop-endpoint --region eu-central-1 --payload '{}' /dev/stdout
  ```
- Enable automatic weekday scheduling:
  ```hcl
  enable_endpoint_scheduler = true
  # Default: starts 7:00 AM UTC, stops 6:00 PM UTC, Mon–Fri
  ```

---

## API

**Input** (`POST /invocations`):
```json
{
  "texts": ["passage: text to embed", "passage: another text"],
  "batch_size": 32
}
```

**Output**:
```json
{
  "embeddings": [[0.123, -0.456, ...], ...],
  "dim": 1024
}
```

**Prefix convention** (required by multilingual-e5-large's training objective):
- `"passage: {text}"` for documents at ingest
- `"query: {text}"` for search queries at retrieval
