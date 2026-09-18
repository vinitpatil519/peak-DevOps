#!/usr/bin/env bash
# CloudForge local (free) environment on kind.
#
#   MODE=helm   (default) install add-ons + apps directly with Helm — works offline from Git.
#   MODE=gitops           install Argo CD and hand everything to the root app (needs the repo
#                         pushed to GitHub and REPO_URL updated in gitops/).
#
# Usage: scripts/bootstrap-local.sh            # full setup
#        SKIP_BUILD=1 scripts/bootstrap-local.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MODE="${MODE:-helm}"
CLUSTER=cloudforge
REG_NAME=kind-registry
REG_PORT=5001

require docker kind kubectl istioctl openssl "$HELM"

# ---------------------------------------------------------------- registry + cluster
if [[ "$(docker inspect -f '{{.State.Running}}' "$REG_NAME" 2>/dev/null || true)" != 'true' ]]; then
  log "starting local registry localhost:${REG_PORT}"
  docker run -d --restart=always -p "127.0.0.1:${REG_PORT}:5000" --network bridge --name "$REG_NAME" registry:3
fi

if ! kind get clusters | grep -qx "$CLUSTER"; then
  log "creating kind cluster '$CLUSTER'"
  kind create cluster --config "$ROOT/scripts/kind-config.yaml" --wait 120s
fi
kubectl config use-context "kind-$CLUSTER" >/dev/null

# Point containerd on every node at the registry for localhost:5001/*
for node in $(kind get nodes --name "$CLUSTER"); do
  docker exec "$node" mkdir -p "/etc/containerd/certs.d/localhost:${REG_PORT}"
  printf '[host."http://%s:5000"]\n' "$REG_NAME" | \
    docker exec -i "$node" cp /dev/stdin "/etc/containerd/certs.d/localhost:${REG_PORT}/hosts.toml"
done
docker network connect kind "$REG_NAME" 2>/dev/null || true
kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "localhost:${REG_PORT}"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
EOF

# ---------------------------------------------------------------- images
if [[ -z "${SKIP_BUILD:-}" ]]; then
  for img in api:app-backend web:app-frontend apache-proxy:apache-proxy; do
    name=${img%%:*}; ctx=${img#*:}
    log "building cloudforge/$name:local"
    docker build -q --build-arg APP_VERSION=local -t "cloudforge/$name:local" "$ROOT/$ctx" >/dev/null
    kind load docker-image "cloudforge/$name:local" --name "$CLUSTER"
  done
fi

# ---------------------------------------------------------------- Istio (CNI mode)
if ! kubectl get ns istio-system >/dev/null 2>&1 || ! kubectl -n istio-system get deploy istiod >/dev/null 2>&1; then
  log "installing Istio $ISTIO_VERSION"
  istioctl install -y -f "$ROOT/k8s-manifests/istio/istio-operator.yaml"
fi
kubectl -n istio-system rollout status deploy/istiod --timeout=5m

# ---------------------------------------------------------------- namespaces + secrets
ensure_app_namespaces
ensure_app_secrets
kubectl apply -f "$ROOT/k8s-manifests/bootstrap/jenkins-deployer.yaml" >/dev/null

# ---------------------------------------------------------------- platform
if [[ "$MODE" == "gitops" ]]; then
  install_argocd local
  log "applying Argo CD root app (app-of-apps)"
  kubectl apply -n argocd -f "$ROOT/gitops/root-app.yaml"
  log "Argo CD now syncs add-ons and apps from Git. Watch: kubectl -n argocd get applications -w"
else
  install_addons local
  install_apps local
  install_argocd local   # installed for exploration; apps above are Helm-managed in this mode
fi

log "done. Add to your hosts file (C:\\Windows\\System32\\drivers\\etc\\hosts or /etc/hosts):"
echo "    127.0.0.1 cloudforge.local preview.cloudforge.local"
echo
echo "  App:        http://cloudforge.local"
echo "  Grafana:    http://cloudforge.local/grafana   (admin / \$(kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d))"
echo "  Argo CD:    kubectl -n argocd port-forward svc/argocd-server 8443:443  -> https://localhost:8443"
echo "              password: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
echo "  Rollouts:   kubectl argo rollouts get rollout backend-api -n backend --watch"
