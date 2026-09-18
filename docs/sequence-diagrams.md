# Sequence diagrams

## 1. Browse catalog (cache miss, then hit)

```mermaid
sequenceDiagram
    autonumber
    actor U as Browser
    participant N as NGINX Ingress<br/>(+ sidecar)
    participant F as frontend pod<br/>NGINX
    participant A as apache-proxy
    participant API as backend-api<br/>FastAPI
    participant R as Redis
    participant P as PostgreSQL

    U->>N: GET /api/v1/products (Host: cloudforge.local)
    N->>F: mTLS (SPIFFE ns/ingress-nginx) — AuthorizationPolicy allows
    F->>A: proxy /api/ → apache-proxy.backend:8080 (X-Request-ID)
    A->>A: /api/* allowed · set/propagate X-Request-ID
    A->>API: mTLS via VirtualService (stable 100 / canary 0)
    API->>R: GET products:all
    R-->>API: (nil) miss
    API->>P: SELECT * FROM products ORDER BY id
    P-->>API: rows
    API->>R: SET products:all EX 60
    API-->>A: 200 JSON
    A-->>F: 200 + X-Served-By: apache-proxy
    F-->>N: 200
    N-->>U: 200
    Note over API: http_requests_total++, latency histogram,<br/>cloudforge_cache_events_total{result="miss"}++
    U->>N: GET /api/v1/products (again)
    N->>F: …
    F->>A: …
    A->>API: …
    API->>R: GET products:all
    R-->>API: cached JSON (hit)
    API-->>U: 200 (no DB round-trip)
```

## 2. Checkout (order creation, concurrency-safe)

```mermaid
sequenceDiagram
    autonumber
    actor U as Browser
    participant API as backend-api
    participant P as PostgreSQL
    participant R as Redis
    U->>API: POST /api/v1/orders {product_id, quantity, email}
    API->>API: Pydantic validation (422 on bad input)
    API->>P: BEGIN; SELECT … FROM products WHERE id=$1 FOR UPDATE
    alt stock < quantity
        API->>P: ROLLBACK
        API-->>U: 409 insufficient stock
    else enough stock
        API->>P: UPDATE products SET stock = stock - q; INSERT INTO orders …; COMMIT
        API->>R: DEL products:all stats:summary product:{id}
        API->>API: orders_created_total{product}++, revenue += total
        API-->>U: 201 order
    end
```

## 3. CI → GitOps → deploy

```mermaid
sequenceDiagram
    autonumber
    actor Dev as Developer
    participant GH as GitHub
    participant J as Jenkins
    participant SQ as SonarQube
    participant REG as Registry (ECR / kind)
    participant CD as Argo CD
    participant K as Kubernetes
    Dev->>GH: git push main
    GH-->>J: webhook / branch scan
    J->>J: pytest · vitest · ruff · eslint
    J->>SQ: sonar-scanner (backend, frontend)
    SQ-->>J: quality gate webhook (OK)
    par security
        J->>J: OWASP Dependency-Check (fail CVSS ≥ 9)
    and
        J->>J: Trivy fs (vuln+secret) + config (Terraform/Helm/Dockerfile)
    end
    J->>J: docker build api / web / apache-proxy (tag = gitsha-build)
    J->>J: Trivy image (fail HIGH/CRITICAL fixable) + CycloneDX SBOM
    J->>REG: docker push
    J->>J: helm lint + render + kubeconform
    J->>GH: commit gitops/environments/<env>/*.yaml image.tag [skip ci]
    GH-->>CD: repo change detected
    CD->>K: sync waves 0..4 (platform → data → api → proxy → web)
    K-->>CD: Healthy / Progressing (Rollouts)
```

## 4. Backend canary with automated analysis

```mermaid
sequenceDiagram
    autonumber
    participant CD as Argo CD
    participant RO as Argo Rollouts
    participant VS as Istio VirtualService
    participant PR as Prometheus
    CD->>RO: Rollout backend-api spec.template changed
    RO->>RO: create canary ReplicaSet (hash H2)
    RO->>VS: weights stable 90 / canary 10
    RO->>RO: pause 2m
    RO->>PR: AnalysisRun: success rate & p95 for pods backend-api-H2-*
    alt success ≥ 99% and p95 ≤ 500ms
        PR-->>RO: pass (4 samples)
        RO->>VS: 75/25 → pause → 50/50 → pause → 0/100
        RO->>RO: scale down old ReplicaSet (stable = H2)
    else failed
        PR-->>RO: fail
        RO->>VS: 100 / 0 (abort)
        RO->>RO: Degraded → alert CloudForgeRolloutDegraded
    end
```

## 5. Frontend blue/green

```mermaid
sequenceDiagram
    autonumber
    participant RO as Argo Rollouts
    participant ACT as Service frontend (active)
    participant PRE as Service frontend-preview
    participant JOB as Smoke-test Job
    actor Op as Release manager
    RO->>RO: new ReplicaSet "green" (blue keeps serving)
    RO->>PRE: selector → green hash
    RO->>JOB: prePromotionAnalysis (curl /, /nginx-health, /api/v1/info via preview)
    JOB-->>RO: success
    Note over Op,PRE: testers verify http://preview.cloudforge.local
    Op->>RO: kubectl argo rollouts promote frontend
    RO->>ACT: selector → green hash (instant cut-over)
    RO->>RO: keep blue 60s (scaleDownDelaySeconds) for fast rollback, then scale down
```

## 6. Secret delivery on EKS

```mermaid
sequenceDiagram
    autonumber
    participant TF as Terraform
    participant SM as AWS Secrets Manager
    participant ESO as External Secrets Operator
    participant PI as EKS Pod Identity agent
    participant K as Kubernetes Secret
    participant POD as backend-api pod
    TF->>SM: random_password → cloudforge/dev/app {db_password, redis_password}
    ESO->>PI: credentials for SA external-secrets/external-secrets
    PI-->>ESO: temporary role creds (read cloudforge/dev/*)
    ESO->>SM: GetSecretValue (every 1h)
    ESO->>K: backend-credentials / postgres-credentials / redis-credentials
    POD->>K: envFrom secretRef (KMS envelope-encrypted at rest)
```

## 7. Alerting path

```mermaid
sequenceDiagram
    autonumber
    participant APP as backend-api
    participant PR as Prometheus
    participant AM as Alertmanager
    participant CH as Chat / Pager webhook
    actor SRE as On-call
    APP-->>PR: http_requests_total{status="500"} rising
    PR->>PR: recording rule cloudforge:http_errors:ratio_rate5m
    PR->>PR: CloudForgeErrorBudgetFastBurn (5m & 1h > 14.4× budget) for 2m
    PR->>AM: firing (severity=critical)
    AM->>CH: route critical → pager + chat (grouped, inhibit warnings)
    CH-->>SRE: page with runbook_url
    SRE->>SRE: docs/runbooks.md#error-budget-burn → Grafana → Loki (request_id)
```
