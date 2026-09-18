# CloudForge Platform

Production-style DevOps/SRE project: a 3-tier online store (React, Apache, FastAPI, PostgreSQL, Redis) with Jenkins CI, Argo CD GitOps, Helm, Istio mTLS, canary/blue-green releases, Prometheus/Grafana/Loki, Terraform on AWS EKS and Ansible. The same Helm charts run **free on kind/minikube** or on **AWS EKS**; only values files differ.

## Architecture

```mermaid
flowchart LR
    U([Client browser]) --> NG[NGINX Ingress]
    NG -->|mTLS| FE["Frontend<br/>React + NGINX<br/>blue/green"]
    FE -->|"/api mTLS"| AP["Apache<br/>reverse proxy"]
    AP -->|"mTLS, canary weights"| API["FastAPI backend<br/>canary"]
    API --> R[("Redis cache")]
    API --> P[("PostgreSQL")]

    subgraph Mesh["Istio service mesh - STRICT mTLS"]
        FE
        AP
        API
        R
        P
    end

    API -. metrics .-> PR[Prometheus] --> GF[Grafana]
    API -. logs .-> FB[Fluent Bit] --> LK[Loki] --> GF
    PR --> AM[Alertmanager]

    DEV([Developer]) -->|git push| GH[(GitHub)]
    GH --> J[Jenkins CI]
    J -->|push images| REG[(Registry<br/>kind or ECR)]
    J -->|commit image tag| GH
    GH -->|watch| CD[Argo CD]
    CD -->|sync| Mesh
    REG -->|pull| Mesh
```

**Jenkins builds and tests, Git records the decision, Argo CD deploys, Istio secures traffic, Prometheus/Grafana/Loki show what is happening.**

## Technologies

| Area | Technology (role) |
|---|---|
| App | **React 19 + Vite 7** (storefront SPA), **FastAPI + Pydantic** (REST API, validation, `CF_*` config), **SQLAlchemy async + asyncpg** (DB access, row locks stop overselling), **redis-py** (read-through cache, failures never break requests), **Gunicorn + Uvicorn** (server), **prometheus-client + python-json-logger** (metrics, JSON logs) |
| Data | **PostgreSQL 17** (products, orders), **Redis 8** (disposable cache) |
| Web tier | **NGINX** (serves SPA, proxies `/api/`), **Apache httpd** (reverse proxy: path allow-list, request-ID, timeouts) |
| Testing | **pytest, httpx, aiosqlite, fakeredis** (backend), **vitest, Testing Library, ESLint** (frontend), **ruff** (lint), **SonarQube** (quality gate), **k6** (load), **kubeconform** (manifests), `smoke-test.sh` (e2e) |
| Containers | **Docker** (3 multi-stage non-root images), **Docker Compose** (local stack), **kind / minikube** (free clusters), local registry |
| Delivery | **Helm** (6 charts), **Argo CD + ApplicationSet + AppProject** (GitOps), **Argo Rollouts** (canary, blue/green), **Kustomize**, **Renovate** (dependency PRs) |
| CI/CD | **Jenkins + JCasC** (pipeline, commits image tag only), **GitHub Actions** (PR checks), **OWASP Dependency-Check**, **Trivy** (fs, IaC, image, SBOM), **yq**, **pre-commit + gitleaks** |
| Traffic | **NGINX Ingress** (edge, TLS, rate limit), **Istio + CNI** (mTLS, retries, canary weights), **Istio Gateway** (alternate edge), **cert-manager** (TLS certs), **ExternalDNS + AWS LB Controller** (DNS, NLBs on EKS), Cloudflare (optional) |
| Scaling | **metrics-server + HPA**, **VPA** (recommend only), **Cluster Autoscaler** (EKS), **PDB**, probes, Postgres backup **CronJob** |
| Security | **Pod Security Standards**, **NetworkPolicy**, **Istio AuthorizationPolicy**, **RBAC**, **ResourceQuota/LimitRange**, **External Secrets + Secrets Manager + KMS**, **EKS Pod Identity + access entries** |
| Observability | **Prometheus** (metrics, 19 alerts), **Grafana** (4 dashboards as code), **Loki + Fluent Bit** (logs), **Alertmanager**, postgres/redis/apache **exporters** |
| Infra | **Terraform** (modules: vpc, security-groups, iam, eks, ecr, s3, route53), **Ansible** (roles: docker, kubectl, helm, monitoring, jenkins), **AWS** (EKS, VPC, ECR, S3, Route 53, IAM, CloudWatch), Makefile + shell scripts |

## Runtime topology

```mermaid
flowchart TB
    client([Client]) --> ingress

    subgraph ns_ingress["ns: ingress-nginx - sidecar outbound only"]
        ingress[ingress-nginx controller]
    end
    subgraph ns_istio["ns: istio-system"]
        istiod["istiod<br/>CA and config"]
        igw["istio-ingressgateway<br/>alternate edge"]
    end
    subgraph ns_fe["ns: frontend - PSS restricted - Istio injection"]
        fe["frontend Rollout<br/>NGINX + React<br/>blue/green"]
        fe_prev[frontend-preview Service]
    end
    subgraph ns_be["ns: backend - PSS restricted - Istio injection"]
        apache["apache-proxy Deployment"]
        api["backend-api Rollout<br/>FastAPI - canary"]
    end
    subgraph ns_db["ns: database - PSS restricted - Istio injection"]
        pg[("postgres StatefulSet<br/>exporter + backup CronJob")]
        redis[("redis StatefulSet<br/>exporter")]
    end
    subgraph ns_mon["ns: monitoring"]
        prom[Prometheus]
        graf[Grafana]
        loki[Loki]
        fb[Fluent Bit DaemonSet]
        am[Alertmanager]
    end

    ingress -->|mTLS| fe
    igw -->|mTLS| fe
    fe -->|"/api/* mTLS"| apache
    apache -->|"mTLS, stable/canary weights"| api
    api -->|"mTLS 5432"| pg
    api -->|"mTLS 6379"| redis
    istiod -. certificates and config .-> fe
    istiod -. certificates and config .-> apache
    istiod -. certificates and config .-> api
    prom -. scrape .-> fe
    prom -. scrape .-> apache
    prom -. scrape .-> api
    prom -. exporters .-> pg
    prom -. exporters .-> redis
    fb -. tail container logs .-> loki
    graf --> prom
    graf --> loki
    prom --> am
```

## Request flows

```mermaid
sequenceDiagram
    autonumber
    actor U as Browser
    participant N as NGINX Ingress
    participant F as Frontend NGINX
    participant A as Apache proxy
    participant API as FastAPI
    participant R as Redis
    participant P as PostgreSQL

    U->>N: GET /api/v1/products
    N->>F: forward over mTLS
    F->>A: proxy /api/ with X-Request-ID
    A->>A: allow /api/* and set or keep request id
    A->>API: forward over mTLS
    API->>R: GET products:all
    R-->>API: miss
    API->>P: SELECT products ORDER BY id
    P-->>API: rows
    API->>R: SET products:all with 60s TTL
    API-->>U: 200 JSON via Apache, frontend, ingress
    U->>API: GET /api/v1/products again
    API->>R: GET products:all
    R-->>API: hit
    API-->>U: 200 JSON with no database query
```

```mermaid
sequenceDiagram
    autonumber
    actor U as Browser
    participant API as FastAPI
    participant P as PostgreSQL
    participant R as Redis

    U->>API: POST /api/v1/orders
    API->>API: Pydantic validation (422 on bad input)
    API->>P: BEGIN and SELECT product FOR UPDATE
    alt stock less than quantity
        API->>P: ROLLBACK
        API-->>U: 409 insufficient stock
    else enough stock
        API->>P: UPDATE stock, INSERT order, COMMIT
        API->>R: DEL products:all, stats:summary, product id
        API->>API: orders_created_total and revenue counters increase
        API-->>U: 201 order
    end
```

```mermaid
flowchart LR
    user([Browser]) -->|":3000"| web["web<br/>NGINX + React<br/>network: edge"]
    web --> apache["apache-proxy<br/>networks: edge + app"]
    apache --> api["api - FastAPI<br/>networks: app + data"]
    subgraph data ["network: data - internal only"]
        pg[("postgres")]
        redis[("redis")]
    end
    api --> pg
    api --> redis
    prom["prometheus<br/>profile: observability"] -. scrape .-> api
    graf["grafana<br/>profile: observability"] --> prom
```

## CI/CD

CI builds, Git decides, Argo CD deploys. Jenkins never runs `kubectl` or `helm`. Image tag is `<git sha>-<build number>`. The promotion commit carries `[skip ci]`.

```mermaid
flowchart LR
    A[Developer git push] --> B[Jenkins Checkout]
    B --> C["Unit tests in parallel<br/>ruff + pytest | eslint + vitest + build"]
    C --> D[SonarQube scan]
    D --> E{Quality gate}
    E -->|red| X1([Build fails])
    E -->|green| F["Security scans in parallel<br/>OWASP Dependency-Check | Trivy fs + IaC"]
    F --> G["docker build x3 in parallel<br/>api, web, apache-proxy"]
    G --> H["Trivy image scan<br/>+ CycloneDX SBOM"]
    H --> I[Push images to registry<br/>main branch only]
    I --> J["helm lint, render,<br/>kubeconform"]
    J --> K["yq bumps image tag in<br/>gitops/environments/env"]
    K --> L["git commit with skip ci<br/>+ git push"]
    L --> M[Argo CD detects commit]
    M --> N{Rollout strategy}
    N -->|backend| O["Canary<br/>10, 25, 50, 100 percent<br/>Prometheus analysis"]
    N -->|frontend| P["Blue/green<br/>preview, smoke Job,<br/>manual promote"]
```

## GitOps

```mermaid
flowchart TB
    root["cloudforge-root<br/>app of apps<br/>gitops/root-app.yaml"] --> proj["AppProjects<br/>cloudforge and cloudforge-platform"]
    root --> appset["ApplicationSet: cloudforge<br/>cluster x chart matrix"]
    root --> addons["ApplicationSet: cloudforge-addons<br/>upstream Helm add-ons"]
    root --> eksaddons["ApplicationSet: cloudforge-addons-eks<br/>AWS-only add-ons"]

    appset --> a0["platform-env<br/>wave 0"]
    appset --> a1["postgres-env, redis-env<br/>wave 1"]
    appset --> a2["backend-env<br/>wave 2"]
    appset --> a3["apache-proxy-env<br/>wave 3"]
    appset --> a4["frontend-env<br/>wave 4"]

    charts[("helm-charts/charts")] --> appset
    values[("gitops/environments/env/chart.yaml")] --> appset
```

```mermaid
flowchart LR
    w4["-4<br/>metrics-server<br/>AWS LB controller"] --> w3["-3<br/>cert-manager<br/>Argo Rollouts<br/>VPA<br/>Cluster Autoscaler<br/>External Secrets"]
    w3 --> w2["-2<br/>kube-prometheus-stack<br/>ExternalDNS"]
    w2 --> w1["-1<br/>Loki<br/>Fluent Bit<br/>ingress-nginx<br/>ClusterSecretStore"]
    w1 --> p0["0<br/>platform chart<br/>namespaces, policies, mesh"]
    p0 --> p1["1<br/>postgres and redis"]
    p1 --> p2["2<br/>backend"]
    p2 --> p3["3<br/>apache-proxy"]
    p3 --> p4["4<br/>frontend"]
```

Rollback: canary failure is automatic; otherwise `git revert` the promotion commit.

## Release strategies

Backend uses canary (10, 25, 50, 100 % via Istio, gated by Prometheus success rate >= 99 % and p95 <= 500 ms). Frontend uses blue/green because a browser must not mix `index.html` and assets from different versions.

```mermaid
sequenceDiagram
    autonumber
    participant CD as Argo CD
    participant RO as Argo Rollouts
    participant VS as Istio VirtualService
    participant PR as Prometheus

    CD->>RO: Rollout template changed (new image tag)
    RO->>RO: create canary ReplicaSet
    RO->>VS: weights stable 90, canary 10
    RO->>RO: pause 2 minutes
    RO->>PR: AnalysisRun for canary pods only
    alt success rate 99 percent or more and p95 500 ms or less
        PR-->>RO: pass
        RO->>VS: 75/25, then 50/50, then 0/100
        RO->>RO: scale down old ReplicaSet
    else analysis failed
        PR-->>RO: fail
        RO->>VS: back to stable 100, canary 0
        RO->>RO: mark Degraded and raise alert
    end
```

```mermaid
sequenceDiagram
    autonumber
    participant RO as Argo Rollouts
    participant ACT as Service frontend (active)
    participant PRE as Service frontend-preview
    participant JOB as Smoke-test Job
    actor Op as Release manager

    RO->>RO: start new ReplicaSet (green) while blue keeps serving
    RO->>PRE: selector points to green
    RO->>JOB: prePromotionAnalysis: curl /, /nginx-health, /api/v1/info via preview
    JOB-->>RO: success
    Note over Op,PRE: testers open preview.cloudforge.local
    Op->>RO: kubectl argo rollouts promote frontend
    RO->>ACT: selector switches to green (instant)
    RO->>RO: keep blue 60 s for fast rollback, then scale down
```

## Security

```mermaid
flowchart LR
    subgraph L1["1 - Supply chain"]
        s1[SonarQube quality gate]
        s2[OWASP Dependency-Check]
        s3[Trivy fs, IaC, image]
        s4[CycloneDX SBOM]
        s5[ECR immutable tags and scan on push]
        s6[gitleaks pre-commit]
    end
    subgraph L2["2 - Cluster admission"]
        a1[Pod Security Standards restricted]
        a2[ResourceQuota and LimitRange]
        a3["non-root, read-only rootfs,<br/>drop ALL caps, seccomp"]
    end
    subgraph L3["3 - Network"]
        n1[NetworkPolicy default-deny<br/>plus explicit allows]
        n2[Istio STRICT mTLS]
        n3[AuthorizationPolicy deny-all<br/>plus SPIFFE identity allows]
    end
    subgraph L4["4 - Identity and secrets"]
        i1[RBAC roles]
        i2[EKS access entries]
        i3[Pod Identity per controller]
        i4[Secrets Manager to External Secrets]
        i5[KMS envelope encryption]
    end
    L1 --> L2 --> L3 --> L4
```

```mermaid
sequenceDiagram
    autonumber
    participant TF as Terraform
    participant SM as AWS Secrets Manager
    participant ESO as External Secrets Operator
    participant PI as EKS Pod Identity
    participant K as Kubernetes Secret
    participant POD as backend-api pod

    TF->>SM: random passwords stored as cloudforge/dev/app
    ESO->>PI: request credentials for its service account
    PI-->>ESO: temporary role credentials
    ESO->>SM: GetSecretValue (hourly)
    ESO->>K: create backend, postgres, redis credential Secrets
    POD->>K: read via envFrom (KMS encrypted at rest)
```

## Observability

SLO: 99.5 % success, p95 < 500 ms. `X-Request-ID` links a request to its logs across tiers. Alert runbooks: [docs/runbooks.md](docs/runbooks.md).

```mermaid
flowchart LR
    subgraph Sources
        app["FastAPI /metrics<br/>via Istio metrics merge :15020"]
        mesh["Envoy sidecars<br/>istio_requests_total"]
        deps["postgres, redis, apache<br/>exporters"]
        node["node-exporter<br/>kube-state-metrics<br/>cAdvisor"]
        logs["Pod stdout JSON<br/>FastAPI, NGINX, Apache, Envoy"]
    end
    app --> prom[Prometheus]
    mesh --> prom
    deps --> prom
    node --> prom
    logs --> fb[Fluent Bit DaemonSet] --> loki[Loki]
    prom --> rules["PrometheusRule<br/>SLO burn-rate and health alerts"]
    rules --> am[Alertmanager]
    am --> chat["Chat and pager webhooks"]
    prom --> graf[Grafana]
    loki --> graf
    graf --> dash["Dashboards: Cluster, Nodes,<br/>Application, Business"]
```

```mermaid
sequenceDiagram
    autonumber
    participant APP as backend-api
    participant PR as Prometheus
    participant AM as Alertmanager
    participant CH as Chat or pager
    actor SRE as On-call engineer

    APP-->>PR: http_requests_total with status 500 rising
    PR->>PR: recording rule for 5xx ratio
    PR->>PR: ErrorBudgetFastBurn true for 2 minutes
    PR->>AM: firing, severity critical
    AM->>CH: grouped notification with runbook link
    CH-->>SRE: page
    SRE->>SRE: follow runbook, Grafana, then Loki by request id
```

## AWS and provisioning

```mermaid
flowchart TB
    subgraph aws["AWS account - us-east-1"]
        r53["Route 53 zone<br/>ExternalDNS records"]
        ecr[("ECR: api, web, apache-proxy<br/>immutable, scan on push")]
        sm[("Secrets Manager<br/>cloudforge/dev/app")]
        s3l[("S3: Loki chunks")]
        s3b[("S3: PostgreSQL backups")]
        kms["KMS: EKS secrets"]
        subgraph vpc["VPC 10.40.0.0/16 - 3 AZ"]
            subgraph pub[Public subnets]
                nlb["NLB to ingress-nginx"]
                nlb2["NLB to Istio gateway"]
                nat[NAT gateway]
            end
            subgraph priv[Private subnets]
                cp["EKS control plane ENIs<br/>private + CIDR-restricted public API"]
                ng1["Managed node group: system"]
                ng2["Managed node group: apps - Spot"]
            end
            s3ep[S3 gateway endpoint]
        end
    end
    nlb --> ng1
    nlb --> ng2
    ng2 --> nat
    ng2 --> s3ep --> s3l
    s3ep --> s3b
    ng2 -->|pull images| ecr
    ng1 -->|Pod Identity| sm
    cp --- kms
```

EKS costs about $8-12/day: run `make eks-down` after demos.

```mermaid
flowchart LR
    choose([Choose a path]) --> A["A. Docker Compose<br/>free, app only"]
    choose --> B["B. kind + Helm<br/>free, full platform"]
    choose --> C["C. kind + GitOps<br/>free, Argo CD + Jenkins"]
    choose --> D["D. AWS EKS<br/>paid, about 8-12 USD per day"]
    D --> tf["make tf-bootstrap, tf-plan, tf-apply"]
    tf --> wire["copy Terraform outputs into gitops values"]
    wire --> up["make eks-up"]
    up --> ci["Jenkins TARGET_ENV=eks builds images"]
    ci --> down["make eks-down when finished"]
```

## Quick start

```bash
cp .env.example .env && docker compose up --build -d   # A. app only: http://localhost:3000
make kind-up && make smoke && make canary              # B. full platform on kind (free)
make kind-gitops                                       # C. kind + Argo CD
make tf-bootstrap tf-plan tf-apply eks-up              # D. AWS EKS (paid)
make eks-down                                          # tear down
```

Windows: run in WSL2. `make help` lists all targets. Docs: [`docs/`](docs/) (architecture, setup, CI/CD, strategies, observability, security, runbooks).

**Known trade-offs:** ingress-nginx is past community end-of-maintenance (Istio Gateway is the migration target); Jenkins mounts the Docker socket (local lab only); PostgreSQL/Redis are single-replica (use RDS/ElastiCache in production); EKS values contain placeholders (account ID, domain) to replace with Terraform outputs.
