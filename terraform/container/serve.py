"""
SageMaker inference adapter for intfloat/multilingual-e5-large.

Contract:
  GET  /ping         → {"status": "healthy"}  (SageMaker health check)
  POST /invocations  → embed a batch of texts

Request body:
  {
    "texts": ["passage: first text", "passage: second text"],
    "batch_size": 32
  }

Response body:
  {
    "embeddings": [[0.123, -0.456, ...], ...],  # list of float lists
    "dim": 1024
  }

Caller conventions:
  - Prefix documents with "passage: " at ingest time (chunker_service.py)
  - Prefix queries   with "query: "   at retrieval time (rag_backend.py)
  This asymmetric prefix is required by multilingual-e5-large's training objective
  and significantly improves retrieval precision.

Embeddings are L2-normalized (unit vectors), so cosine similarity == dot product.
"""

import os
import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI, HTTPException
from fastapi.responses import JSONResponse
from pydantic import BaseModel
from sentence_transformers import SentenceTransformer

logger = logging.getLogger("embedding-serve")
logging.basicConfig(level=logging.INFO)

MODEL_NAME = os.environ.get("MODEL_NAME", "intfloat/multilingual-e5-large")

# Load model at startup — weights are baked into the image so this is fast
model: SentenceTransformer | None = None


@asynccontextmanager
async def lifespan(app: FastAPI):
    global model
    logger.info(f"Loading model: {MODEL_NAME}")
    model = SentenceTransformer(MODEL_NAME)
    logger.info(f"Model loaded. Embedding dim: {model.get_sentence_embedding_dimension()}")
    yield
    model = None


app = FastAPI(lifespan=lifespan)


class EmbedRequest(BaseModel):
    texts: list[str]
    batch_size: int = 32


@app.get("/ping")
def ping():
    """SageMaker health check endpoint."""
    if model is None:
        raise HTTPException(status_code=503, detail="Model not loaded")
    return JSONResponse({"status": "healthy"})


@app.post("/invocations")
def invocations(request: EmbedRequest):
    """
    Embed a batch of texts. Returns L2-normalized vectors.
    Expected input size: up to 512 tokens per text (multilingual-e5-large limit).
    Typical batch: 32 chunks of ~400 tokens each.
    """
    if model is None:
        raise HTTPException(status_code=503, detail="Model not loaded")

    if not request.texts:
        raise HTTPException(status_code=400, detail="texts list is empty")

    try:
        embeddings = model.encode(
            request.texts,
            batch_size=request.batch_size,
            normalize_embeddings=True,  # L2-normalize so cosine sim == dot product
            show_progress_bar=False,
        )
        return JSONResponse({
            "embeddings": embeddings.tolist(),
            "dim": embeddings.shape[1],
        })
    except Exception as e:
        logger.error(f"Embedding failed: {e}")
        raise HTTPException(status_code=500, detail=str(e))
