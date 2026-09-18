#!/usr/bin/env bash
# Shared helpers for CloudForge scripts.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELM="${HELM:-helm}"

# Pinned add-on versions (keep in sync with gitops/argocd/addons/addons.yaml).
ARGOCD_VERSION="${ARGOCD_VERSION:-v3.1.8}"
ISTIO_VERSION="${ISTIO_VERSION:-1.27.1}"
V_METRICS_SERVER="3.13.0"
V_CERT_MANAGER="v1.18.2"
V_ARGO_ROLLOUTS="2.40.4"
V_KPS="77.12.0"
V_LOKI="6.41.1"
V_FLUENT_BIT="0.53.0"
V_INGRESS_NGINX="4.13.3"
V_VPA="4.8.0"

APP_NAMESPACES=(frontend backend database)

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

require() {
  for bin in "$@"; do
    command -v "$bin" >/dev/null 2>&1 || die "'$bin' not found in PATH (see docs/setup.md)"
  done
}

rand() { openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c "${1:-32}"; }

# Create namespaces up front with the same labels the platform chart applies,
# so Secrets can be created before Argo CD/Helm installs the apps.
ensure_app_namespaces() {
  for ns in "${APP_NAMESPACES[@]}"; do
    kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    kubectl label namespace "$ns" --overwrite \
      istio-injection=enabled \
      pod-security.kubernetes.io/enforce=restricted \
      pod-security.kubernetes.io/warn=restricted \
      pod-security.kubernetes.io/audit=restricted \
      app.kubernetes.io/managed-by=Helm >/dev/null
    # Let the 'platform' Helm release adopt the pre-created namespace.
    kubectl annotate namespace "$ns" --overwrite \
      meta.helm.sh/release-name=platform meta.helm.sh/release-namespace=istio-system >/dev/null
  done
  kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl label namespace monitoring --overwrite istio-injection=disabled \
    pod-security.kubernetes.io/enforce=privileged >/dev/null
}

# Random credentials, created once (re-runs keep existing values).
ensure_app_secrets() {
  if kubectl -n database get secret postgres-credentials >/dev/null 2>&1; then
    log "application secrets already exist — keeping them"
  else
    log "generating application secrets"
    local db redis
    db="$(rand 32)"; redis="$(rand 32)"
    kubectl -n database create secret generic postgres-credentials --from-literal=password="$db"
    kubectl -n database create secret generic redis-credentials --from-literal=password="$redis"
    kubectl -n backend create secret generic backend-credentials \
      --from-literal=CF_DB_PASSWORD="$db" --from-literal=CF_REDIS_PASSWORD="$redis"
  fi
  if ! kubectl -n monitoring get secret grafana-admin >/dev/null 2>&1; then
    kubectl -n monitoring create secret generic grafana-admin \
      --from-literal=admin-user=admin --from-literal=admin-password="$(rand 24)"
  fi
}

helm_repos() {
  "$HELM" repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ --force-update >/dev/null
  "$HELM" repo add jetstack https://charts.jetstack.io --force-update >/dev/null
  "$HELM" repo add argo https://argoproj.github.io/argo-helm --force-update >/dev/null
  "$HELM" repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update >/dev/null
  "$HELM" repo add grafana https://grafana.github.io/helm-charts --force-update >/dev/null
  "$HELM" repo add fluent https://fluent.github.io/helm-charts --force-update >/dev/null
  "$HELM" repo add ingress-nginx https://kubernetes.github.io/ingress-nginx --force-update >/dev/null
  "$HELM" repo add fairwinds-stable https://charts.fairwinds.com/stable --force-update >/dev/null
  "$HELM" repo update >/dev/null
}

# helm_addon <release> <chart> <version> <namespace> <values-dir> <env>
helm_addon() {
  local name=$1 chart=$2 version=$3 ns=$4 dir=$5 env=$6
  local args=(upgrade --install "$name" "$chart" --version "$version" -n "$ns" --create-namespace --wait --timeout 10m)
  [[ -f "$ROOT/$dir/values.yaml" ]] && args+=(-f "$ROOT/$dir/values.yaml")
  [[ -f "$ROOT/$dir/values-$env.yaml" ]] && args+=(-f "$ROOT/$dir/values-$env.yaml")
  log "add-on $name ($chart $version)"
  "$HELM" "${args[@]}"
}

install_addons() {
  local env=$1
  helm_repos
  helm_addon metrics-server metrics-server/metrics-server "$V_METRICS_SERVER" kube-system gitops/addons/metrics-server "$env"
  helm_addon cert-manager jetstack/cert-manager "$V_CERT_MANAGER" cert-manager gitops/addons/cert-manager "$env"
  helm_addon argo-rollouts argo/argo-rollouts "$V_ARGO_ROLLOUTS" argo-rollouts monitoring/argo-rollouts "$env"
  helm_addon vpa fairwinds-stable/vpa "$V_VPA" vpa gitops/addons/vpa "$env"
  helm_addon kube-prometheus-stack prometheus-community/kube-prometheus-stack "$V_KPS" monitoring monitoring/kube-prometheus-stack "$env"
  helm_addon loki grafana/loki "$V_LOKI" monitoring monitoring/loki "$env"
  helm_addon fluent-bit fluent/fluent-bit "$V_FLUENT_BIT" monitoring monitoring/fluent-bit "$env"
  kubectl create namespace ingress-nginx --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl label namespace ingress-nginx istio-injection=enabled --overwrite >/dev/null
  helm_addon ingress-nginx ingress-nginx/ingress-nginx "$V_INGRESS_NGINX" ingress-nginx gitops/addons/ingress-nginx "$env"
}

# helm_app <chart> <namespace> <env>
helm_app() {
  local chart=$1 ns=$2 env=$3
  log "app $chart -> $ns"
  "$HELM" upgrade --install "$chart" "$ROOT/helm-charts/charts/$chart" -n "$ns" \
    -f "$ROOT/gitops/environments/$env/$chart.yaml" --wait --timeout 10m
}

install_apps() {
  local env=$1
  helm_app platform istio-system "$env"
  helm_app postgres database "$env"
  helm_app redis database "$env"
  helm_app backend backend "$env"
  helm_app apache-proxy backend "$env"
  helm_app frontend frontend "$env"
}

install_argocd() {
  local env=$1
  log "Argo CD $ARGOCD_VERSION"
  kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl apply -n argocd --server-side --force-conflicts \
    -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml" >/dev/null
  kubectl apply -f "$ROOT/gitops/argocd/argocd-cm-patch.yaml" >/dev/null
  kubectl -n argocd rollout status deploy/argocd-server --timeout=5m
  kubectl -n argocd rollout status deploy/argocd-applicationset-controller --timeout=5m
  # Register the in-cluster destination with the env label the ApplicationSets select on.
  kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: in-cluster
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: cluster
    cloudforge.dev/env: ${env}
stringData:
  name: in-cluster
  server: https://kubernetes.default.svc
  config: '{"tlsClientConfig":{"insecure":false}}'
EOF
}
