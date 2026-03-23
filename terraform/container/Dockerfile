FROM nvidia/cuda:11.8.0-cudnn8-runtime-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    python3.11 \
    python3.11-distutils \
    curl \
    && curl -sS https://bootstrap.pypa.io/get-pip.py | python3.11 \
    && rm -rf /var/lib/apt/lists/*

# Pin torch to a known-good CUDA 11.8 wheel
RUN python3.11 -m pip install --no-cache-dir \
    torch==2.1.0 \
    --extra-index-url https://download.pytorch.org/whl/cu118

RUN python3.11 -m pip install --no-cache-dir \
    fastapi \
    uvicorn \
    "numpy<2" \
    "transformers==4.44.2" \
    sentence-transformers

# Pre-bake model weights into the image at build time.
# This avoids a cold-download on every container start (~500 MB model).
# Model: intfloat/multilingual-e5-large (560M params, 1024-dim, Apache 2.0)
RUN python3.11 -c "\
from sentence_transformers import SentenceTransformer; \
SentenceTransformer('intfloat/multilingual-e5-large'); \
print('Model weights downloaded successfully')"

COPY serve.py /opt/serve.py

# SageMaker invokes the `serve` executable from PATH — CMD is ignored
RUN printf '#!/bin/sh\nexec python3.11 -m uvicorn serve:app --host 0.0.0.0 --port 8080\n' \
    > /usr/local/bin/serve && chmod +x /usr/local/bin/serve

WORKDIR /opt
