# Runbooks

Each alert in `cloudforge-rules` links here. Pattern: **confirm → contain → diagnose → fix → follow up**.

## Error budget burn

`CloudForgeErrorBudgetFastBurn` (page) / `CloudForgeErrorBudgetSlowBurn` (ticket)

1. **Confirm** — Grafana *CloudForge / Application*: which routes/status codes? Started when?
2. **Recent change?** `kubectl argo rollouts list rollouts -A` and Argo CD history. If a canary
   is running: `kubectl argo rollouts abort backend-api -n backend`. If fully rolled out:
   `git revert` the promotion commit.
3. **Dependencies** — `pg_up`, `redis_up`, Postgres connections panel. `kubectl -n backend logs
   deploy/backend-api -c api --since=10m | grep ERROR` or Loki `{namespace="backend"} | json | level="ERROR"`.
4. **Mesh** — `istioctl proxy-status`; 503 `UF`/`URX` flags in Envoy logs suggest outlier ejection
   or upstream resets.

## CloudForgeHighLatencyP95

Check p95 by route; compare CPU throttling (`container_cpu_cfs_throttled_periods_total`), HPA
at max, DB slow query log (`log_min_duration_statement`), cache hit ratio. Scale: raise HPA
`maxReplicas` in Git; short-term: `kubectl scale` is reverted by HPA — change HPA min instead.

## CloudForgeApiDown

`kubectl -n backend get pods,rollout,analysisrun`. Common causes: DB unreachable (readiness
fails by design), bad image tag (`ImagePullBackOff`), secret missing (`CreateContainerConfigError`
→ `kubectl get externalsecret -n backend`).

## CloudForgePostgresDown / ConnectionsHigh

```bash
kubectl -n database describe pod postgres-0
kubectl -n database logs postgres-0 -c postgres --tail=100
kubectl -n database exec postgres-0 -c postgres -- psql -U cloudforge -c "select state, count(*) from pg_stat_activity group by 1"
```

PVC full → see *PVC filling up*. Restore from backup:

```bash
kubectl -n database run pg-restore --rm -it --image=postgres:17.6-alpine --overrides='{"spec":{"volumes":[{"name":"b","persistentVolumeClaim":{"claimName":"postgres-backups"}}]}}' -- sh
pg_restore --clean --if-exists -h postgres -U cloudforge -d cloudforge /backups/<file>.dump
```

## CloudForgeRedisDown / MemoryHigh

The API keeps working from Postgres (higher latency). Restart is safe (cache only):
`kubectl -n database rollout restart statefulset/redis`. Persistent memory pressure: raise
`maxmemory` in Git or shorten `CF_CACHE_TTL_SECONDS`.

## CloudForgeApacheDown

`kubectl -n backend logs deploy/apache-proxy -c httpd`. Config errors show on start
(`AH00526`). Validate locally: `docker run --rm cloudforge/apache-proxy:local httpd -t`.

## CloudForgePodCrashLooping

`kubectl describe pod` → *Last State* reason: `OOMKilled` (raise memory limit / check VPA
recommendation `kubectl describe vpa -n backend`), `Error` (logs `--previous`).

## CloudForgeHpaMaxedOut

Sustained demand or inefficiency. Check the node pool can grow (Cluster Autoscaler logs on
EKS), then raise `autoscaling.maxReplicas` in `gitops/environments/<env>/<chart>.yaml`.

## CloudForgePdbViolated

A voluntary disruption is blocked or pods are unhealthy. During node drains on EKS, the
single-replica Postgres PDB (`maxUnavailable: 0`) blocks eviction intentionally: schedule a
maintenance window, take a backup, then drain with `--disable-eviction` for that pod.

## CloudForgePvcFillingUp

```bash
kubectl -n database exec postgres-0 -c postgres -- df -h /var/lib/postgresql/data
```

Expand (gp3 supports online expansion): edit the PVC `spec.resources.requests.storage`, and
update `persistence.size` in Git so the StatefulSet template matches.

## CloudForgeRolloutDegraded

```bash
kubectl argo rollouts get rollout <name> -n <ns>
kubectl get analysisrun -n <ns> -o wide
kubectl describe analysisrun <run> -n <ns>      # which metric failed, measured values
```

Fix forward in Git (new tag) or revert the promotion commit. `kubectl argo rollouts retry` only
after the cause is understood.

## CloudForgeBackupFailed

`kubectl -n database logs job/<postgres-backup-...>`. Common: backup PVC full (retention),
mesh egress (Job sidecar), credentials rotated. Run manually:
`kubectl -n database create job --from=cronjob/postgres-backup manual-$(date +%s)`.

## Node CPU / memory / disk

Identify top pods: `kubectl top pods -A --sort-by=memory | head`. On kind the "nodes" share
your laptop — close other workloads or lower replica counts in `gitops/environments/local`.
