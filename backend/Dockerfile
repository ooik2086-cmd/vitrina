FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app
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

# Run as an unprivileged user; uploaded photos live in a mounted volume.
RUN useradd --create-home vitrina && mkdir -p /data/media && chown -R vitrina /data
USER vitrina
ENV VITRINA_MEDIA_DIR=/data/media VITRINA_AUTO_CREATE_SCHEMA=0
EXPOSE 8000
CMD ["sh", "-c", "alembic upgrade head && uvicorn vitrina_api.app:create_app --factory --host 0.0.0.0 --port 8000 --proxy-headers"]
