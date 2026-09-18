# syntax=docker/dockerfile:1.7
# ---------- build stage ----------
FROM node:24-alpine AS build
WORKDIR /src
COPY package.json package-lock.json* ./
RUN if [ -f package-lock.json ]; then npm ci --no-audit --no-fund; else npm install --no-audit --no-fund; fi
COPY . .
RUN npm run build

# ---------- runtime stage: unprivileged NGINX (UID 101, port 8080) ----------
FROM nginxinc/nginx-unprivileged:1.29-alpine AS runtime
ARG APP_VERSION=dev
LABEL org.opencontainers.image.title="cloudforge-web" \
      org.opencontainers.image.version="${APP_VERSION}"
ENV API_UPSTREAM_HOST=apache-proxy:8080 \
    NGINX_ENVSUBST_FILTER=API_
COPY nginx/default.conf.template /etc/nginx/templates/default.conf.template
COPY --from=build /src/dist /usr/share/nginx/html
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s CMD wget -qO- http://127.0.0.1:8080/nginx-health || exit 1
