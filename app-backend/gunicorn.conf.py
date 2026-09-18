import os

bind = "0.0.0.0:8000"
worker_class = "uvicorn.workers.UvicornWorker"
# One worker per pod by default: scale horizontally with HPA, and keep /metrics
# consistent (prometheus_client multiprocess mode not needed).
workers = int(os.getenv("WEB_CONCURRENCY", "1"))
timeout = 30
graceful_timeout = 25
keepalive = 5
accesslog = None
errorlog = "-"
loglevel = os.getenv("CF_LOG_LEVEL", "info").lower()
