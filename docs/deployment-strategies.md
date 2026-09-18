# Deployment strategies

| Workload | Strategy | Traffic control | Gate |
|---|---|---|---|
| backend-api | **Canary** (Argo Rollouts) | Istio VirtualService weights across DestinationRule subsets `stable`/`canary` | Prometheus AnalysisTemplate `backend-success-rate` (success ≥ 99 %, p95 ≤ 500 ms) |
| frontend | **Blue/Green** (Argo Rollouts) | Service selector swap `frontend` (active) / `frontend-preview` | Job-based smoke test + manual promotion |
| apache-proxy | Rolling update, `maxUnavailable: 0` | Kubernetes Service | readiness probe |
| postgres, redis | StatefulSet rolling update | — | readiness probe; PDB |

Toggle with `rollout.enabled` in the chart values (false = plain Deployment + RollingUpdate,
e.g. on clusters without Argo Rollouts).

## Canary (backend)

`helm-charts/charts/backend/templates/rollout.yaml`, `analysistemplate.yaml`, `istio.yaml`

Steps (values `rollout.canary.steps`): 10 % → 2 min → analysis → 25 % → 2 min → 50 % → 5 min → 100 %.

Why subset-level routing: Apache calls one hostname (`backend-api`). Istio splits traffic by
pod label `rollouts-pod-template-hash`, which Argo Rollouts writes into the DestinationRule
subsets. No second Service, no client change, and retries/outlier detection still apply.

The analysis isolates the canary by pod name (`backend-api-<hash>-*`), so errors in the stable
pods do not fail a healthy canary and vice versa. `isNaN(result)` counts "no traffic yet" as
pass so an idle environment does not abort.

Commands:

```bash
kubectl argo rollouts get rollout backend-api -n backend --watch
kubectl argo rollouts promote backend-api -n backend        # skip current pause
kubectl argo rollouts abort backend-api -n backend          # back to stable
kubectl get analysisrun -n backend
```

## Blue/Green (frontend)

`helm-charts/charts/frontend/templates/workload.yaml`

1. New ReplicaSet (green) starts; `frontend-preview` points to it; production still on blue.
2. `prePromotionAnalysis` runs a Job (in-mesh) hitting `/`, `/nginx-health` and
   `/api/v1/info` through the preview Service — the full path to FastAPI.
3. Testers use `preview.cloudforge.local` (ingress restricted to private source ranges).
4. `kubectl argo rollouts promote frontend -n frontend` swaps the active selector atomically.
5. Blue stays up 60 s (`scaleDownDelaySeconds`) for instant rollback.

Set `rollout.autoPromotionEnabled: true` (or `autoPromotionSeconds`) for unattended environments.

## Why canary for the API and blue/green for the SPA?

- API responses are independent per request, so partial traffic exposure gives a statistically
  meaningful error/latency signal at low blast radius.
- A browser loads `index.html` plus hashed assets; mixing versions mid-session can serve an
  `index.html` whose assets live only on the other version. Blue/green keeps each user on one
  consistent version and cuts over atomically.
