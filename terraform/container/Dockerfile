ARG BASE_IMAGE
FROM ${BASE_IMAGE}

# apertus model type is not yet in any released transformers version;
# install from the main branch which already has the architecture registered.
RUN pip install --no-cache-dir \
    git+https://github.com/huggingface/transformers.git \
    fastapi uvicorn httpx

COPY serve.py /opt/serve.py
COPY entrypoint.sh /opt/entrypoint.sh
RUN sed -i 's/\r$//' /opt/entrypoint.sh && chmod +x /opt/entrypoint.sh

ENTRYPOINT ["/bin/bash", "/opt/entrypoint.sh"]
