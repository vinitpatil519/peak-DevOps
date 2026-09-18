#!/usr/bin/env bash
# Demonstrate the backend canary and frontend blue/green without Jenkins:
# build a new image version, load it into kind, bump the rollout, and watch.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require docker kind kubectl kubectl-argo-rollouts
TAG="${1:-v$(date +%H%M%S)}"

log "building cloudforge/api:$TAG and cloudforge/web:$TAG"
docker build -q --build-arg APP_VERSION="$TAG" -t "cloudforge/api:$TAG" "$ROOT/app-backend" >/dev/null
docker build -q --build-arg APP_VERSION="$TAG" -t "cloudforge/web:$TAG" "$ROOT/app-frontend" >/dev/null
kind load docker-image "cloudforge/api:$TAG" "cloudforge/web:$TAG" --name cloudforge

log "backend canary: 10% -> analysis -> 25% -> 50% -> 100% (Istio weights)"
kubectl argo rollouts set image backend-api -n backend api="cloudforge/api:$TAG"

log "frontend blue/green: new ReplicaSet behind frontend-preview, smoke test, manual promote"
kubectl argo rollouts set image frontend -n frontend web="cloudforge/web:$TAG"

cat <<EOF

Watch:
  kubectl argo rollouts get rollout backend-api -n backend --watch
  kubectl get virtualservice backend-api -n backend -o jsonpath='{.spec.http[0].route[*].weight}'
  kubectl argo rollouts get rollout frontend -n frontend --watch
Preview (blue/green): http://preview.cloudforge.local
Promote frontend:     kubectl argo rollouts promote frontend -n frontend
Abort backend:        kubectl argo rollouts abort backend-api -n backend
Note: with Argo CD auto-sync enabled, commit the tag to gitops/environments/local/*.yaml
instead — otherwise self-heal reverts this imperative change.
EOF
