FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .

# Run as an unprivileged user; uploaded photos live in a mounted volume.
RUN useradd --create-home vitrina && mkdir -p /data/media && chown -R vitrina /data
USER vitrina
ENV VITRINA_MEDIA_DIR=/data/media VITRINA_AUTO_CREATE_SCHEMA=0
EXPOSE 8000
CMD ["sh", "-c", "alembic upgrade head && uvicorn vitrina_api.app:create_app --factory --host 0.0.0.0 --port 8000 --proxy-headers"]
