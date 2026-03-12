"""
SageMaker ↔ vLLM adapter.

SageMaker sends inference requests to /invocations and health checks to /ping.
vLLM serves an OpenAI-compatible API on port 8000. This adapter bridges the two.

Input  (POST /invocations): {"inputs": "...", "parameters": {"max_new_tokens": ..., ...}}
Output (POST /invocations): {"generated_text": "..."}
"""

import json
import os
import time
from contextlib import asynccontextmanager

import httpx
import uvicorn
from fastapi import FastAPI, HTTPException
from fastapi.responses import JSONResponse, StreamingResponse

VLLM_BASE = "http://localhost:8000"
MODEL_NAME = os.environ.get("HF_MODEL_ID", "swiss-ai/Apertus-70B-Instruct-2509")


def _wait_for_vllm(timeout: int = 600, interval: int = 5) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            r = httpx.get(f"{VLLM_BASE}/health", timeout=5)
            if r.status_code == 200:
                print("vLLM is ready.")
                return
        except Exception:
            pass
        print("Waiting for vLLM...")
        time.sleep(interval)
    raise RuntimeError("vLLM did not become ready in time.")


@asynccontextmanager
async def lifespan(app: FastAPI):
    _wait_for_vllm()
    yield


app = FastAPI(lifespan=lifespan)


@app.get("/ping")
def ping():
    return JSONResponse({"status": "healthy"})


@app.post("/invocations")
def invocations(body: dict):
    prompt = body.get("inputs", "")
    params = body.get("parameters", {})

    messages = [{"role": "user", "content": prompt}]

    payload = {
        "model": MODEL_NAME,
        "messages": messages,
        "max_tokens": params.get("max_new_tokens", 256),
        "temperature": params.get("temperature", 0.8),
        "top_p": params.get("top_p", 0.9),
        "repetition_penalty": params.get("repetition_penalty", 1.0),
    }

    stop = params.get("stop_sequences") or params.get("stop")
    if stop:
        payload["stop"] = stop

    try:
        r = httpx.post(
            f"{VLLM_BASE}/v1/chat/completions",
            json=payload,
            timeout=120,
        )
        r.raise_for_status()
    except httpx.HTTPStatusError as e:
        raise HTTPException(status_code=502, detail=str(e))

    result = r.json()
    generated_text = result["choices"][0]["message"]["content"]
    return {"generated_text": generated_text}


@app.post("/invocations-response-stream")
async def invocations_stream(body: dict):
    prompt = body.get("inputs", "")
    params = body.get("parameters", {})

    messages = [{"role": "user", "content": prompt}]

    payload = {
        "model": MODEL_NAME,
        "messages": messages,
        "max_tokens": params.get("max_new_tokens", 256),
        "temperature": params.get("temperature", 0.8),
        "top_p": params.get("top_p", 0.9),
        "stream": True,
    }

    stop = params.get("stop_sequences") or params.get("stop")
    if stop:
        payload["stop"] = stop

    async def stream_response():
        async with httpx.AsyncClient() as client:
            async with client.stream(
                "POST",
                f"{VLLM_BASE}/v1/chat/completions",
                json=payload,
                timeout=300,
            ) as r:
                async for line in r.aiter_lines():
                    if not line.startswith("data: "):
                        continue
                    data = line[6:]
                    if data == "[DONE]":
                        break
                    try:
                        obj = json.loads(data)
                        content = obj["choices"][0]["delta"].get("content", "")
                        if content:
                            yield content.encode()
                    except Exception:
                        pass

    return StreamingResponse(stream_response(), media_type="text/plain")


if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8080)
