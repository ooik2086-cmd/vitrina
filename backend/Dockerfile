FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app
# ffmpeg encodes the sellers' promo videos.
RUN apt-get update && apt-get install -y --no-install-recommends ffmpeg && rm -rf /var/lib/apt/lists/*
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .

# Background-removal model (Apache-2.0, see models/README.md). Build with --build-arg CUTOUT_MODEL= to skip it.
ARG CUTOUT_MODEL=isnet-general-use
ARG CUTOUT_SHA256=60920e99c45464f2ba57bee2ad08c919a52bbf852739e96947fbb4358c0d964a
RUN if [ -n "$CUTOUT_MODEL" ]; then \
      python -c "import urllib.request,sys; urllib.request.urlretrieve(sys.argv[1], sys.argv[2])" \
        "https://github.com/danielgatis/rembg/releases/download/v0.0.0/$CUTOUT_MODEL.onnx" "models/$CUTOUT_MODEL.onnx" \
      && echo "$CUTOUT_SHA256  models/$CUTOUT_MODEL.onnx" | sha256sum -c -; fi
ENV VITRINA_CUTOUT_MODEL=/app/models/${CUTOUT_MODEL}.onnx

# Search-by-photo model: MobileNetV2 from the ONNX model zoo (Apache-2.0). Build with --build-arg SEARCH_MODEL= to skip.
ARG SEARCH_MODEL=mobilenetv2-12
ARG SEARCH_SHA256=c0c3f76d93fa3fd6580652a45618618a220fced18babf65774ed169de0432ad5
RUN if [ -n "$SEARCH_MODEL" ]; then \
      python -c "import urllib.request,sys; urllib.request.urlretrieve(sys.argv[1], sys.argv[2])" \
        "https://media.githubusercontent.com/media/onnx/models/main/validated/vision/classification/mobilenet/model/$SEARCH_MODEL.onnx" "models/$SEARCH_MODEL.onnx" \
      && echo "$SEARCH_SHA256  models/$SEARCH_MODEL.onnx" | sha256sum -c -; fi
ENV VITRINA_SEARCH_MODEL=/app/models/${SEARCH_MODEL}.onnx

# Run as an unprivileged user; uploaded photos live in a mounted volume.
RUN useradd --create-home vitrina && mkdir -p /data/media && chown -R vitrina /data
USER vitrina
ENV VITRINA_MEDIA_DIR=/data/media VITRINA_AUTO_CREATE_SCHEMA=0
EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/api/v1/health', timeout=4)"
CMD ["sh", "-c", "alembic upgrade head && uvicorn vitrina_api.app:create_app --factory --host 0.0.0.0 --port 8000 --proxy-headers"]
