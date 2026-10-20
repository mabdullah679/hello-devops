# syntax=docker/dockerfile:1
FROM python:3.13-slim AS deps
ENV PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1
COPY requirements.txt .
RUN pip install --prefix=/install -r requirements.txt

FROM python:3.13-slim
ARG APP_VERSION=dev
ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1 PORT=8080 APP_VERSION=${APP_VERSION}
COPY --from=deps /install /usr/local
RUN useradd --system --uid 10001 --no-create-home app
WORKDIR /app
COPY --chown=app:app app.py .
USER 10001
EXPOSE 8080
HEALTHCHECK --interval=15s --timeout=3s --start-period=5s --retries=3 \
  CMD ["python3", "-c", "import urllib.request,os;urllib.request.urlopen('http://127.0.0.1:%s/livez'%os.environ['PORT'],timeout=2)"]
# exec form: python is PID 1 and receives SIGTERM directly (app handles it)
CMD ["python3", "/app/app.py"]
