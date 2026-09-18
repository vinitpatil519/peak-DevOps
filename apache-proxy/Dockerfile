# syntax=docker/dockerfile:1.7
# Apache HTTPD reverse-proxy tier between the frontend and FastAPI.
# Responsibilities: path routing, request-id propagation, header hygiene, timeouts,
# connection pooling to the API and a JSON access log for Loki.
FROM httpd:2.4-alpine
ARG APP_VERSION=dev
LABEL org.opencontainers.image.title="cloudforge-apache-proxy" \
      org.opencontainers.image.version="${APP_VERSION}"
ENV BACKEND_URL=http://backend-api:8000 \
    LISTEN_PORT=8080
COPY httpd.conf /usr/local/apache2/conf/httpd.conf
COPY conf.d/ /usr/local/apache2/conf.d/
RUN rm -rf /usr/local/apache2/htdocs/* \
 && printf 'ok\n' > /usr/local/apache2/htdocs/apache-health \
 && chown -R 82:82 /usr/local/apache2/logs
# www-data (UID 82 on Alpine) on an unprivileged port.
USER 82:82
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s CMD wget -qO- http://127.0.0.1:8080/apache-health || exit 1
