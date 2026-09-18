# Architecture

CloudForge is a 3-tier storefront (React → Apache → FastAPI → PostgreSQL/Redis) running on
Kubernetes with an Istio mesh, GitOps delivery and a full observability stack. The same Helm
charts deploy to a free local kind cluster and to AWS EKS; only the values files differ.

## 1. System context

```mermaid
flowchart LR
    user([Browser]) -->|HTTPS| cf[Cloudflare DNS/CDN<br/>optional]
    cf --> edge
    dev([Developer]) -->|git push| gh[(GitHub<br/>monorepo)]
    gh -->|webhook / poll| jenkins[Jenkins CI]
    jenkins -->|push images| reg[(Registry<br/>kind: localhost:5001<br/>AWS: ECR)]
    jenkins -->|commit image tags| gh
    gh -->|watch| argocd[Argo CD]
    argocd -->|sync| k8s
    subgraph k8s[Kubernetes cluster: kind or EKS]
        edge[NGINX Ingress<br/>+ Istio IngressGateway]
        app[CloudForge 3-tier app]
        obs[Prometheus · Grafana · Loki · Fluent Bit]
    end
    edge --> app
    app -.metrics/logs.-> obs
    reg -->|pull| app
```

## 2. Runtime topology (namespaces, tiers, mesh)

```mermaid
flowchart TB
    client([Client]) --> ingress

    subgraph ns_ingress[ns: ingress-nginx  · sidecar outbound-only]
        ingress[ingress-nginx controller]
    end
    subgraph ns_istio[ns: istio-system]
        istiod[istiod<br/>CA + xDS]
        igw[istio-ingressgateway<br/>alternate edge]
    end
    subgraph ns_fe[ns: frontend · PSS restricted · istio-injection]
        fe[frontend Rollout<br/>NGINX + React SPA<br/>blue/green]
        fe_prev[frontend-preview Service]
    end
    subgraph ns_be[ns: backend · PSS restricted · istio-injection]
        apache[apache-proxy Deployment<br/>httpd reverse proxy]
        api[backend-api Rollout<br/>FastAPI · canary]
    end
    subgraph ns_db[ns: database · PSS restricted · istio-injection]
        pg[(postgres StatefulSet<br/>+ exporter + backup CronJob)]
        redis[(redis StatefulSet<br/>+ exporter)]
    end
    subgraph ns_mon[ns: monitoring]
        prom[Prometheus]
        graf[Grafana]
        loki[Loki]
        fb[Fluent Bit DaemonSet]
        am[Alertmanager]
    end

    ingress -->|mTLS| fe
    igw -->|mTLS| fe
    fe -->|/api/* mTLS| apache
    apache -->|mTLS · VirtualService<br/>stable/canary weights| api
    api -->|mTLS 5432| pg
    api -->|mTLS 6379| redis
    istiod -. certs/config .-> fe & apache & api & pg & redis
    prom -. scrape :15020 merged metrics .-> fe & apache & api
    prom -. scrape exporters .-> pg & redis & apache
    fb -. tail container logs .-> loki
    graf --> prom & loki
    prom --> am
```

**Why each hop exists**

| Hop | Responsibility |
|---|---|
| NGINX Ingress | Public entry, TLS termination (cert-manager), rate limiting, JSON access logs. Joined to the mesh for outbound mTLS only. |
| Istio IngressGateway | Alternate, mesh-native edge (Gateway + VirtualService); on EKS behind its own NLB. |
| Frontend NGINX | Serves the static React build with security headers; proxies `/api/` to Apache so the browser uses one origin (no CORS). |
| Apache reverse proxy | API gateway tier: path allow-listing (`/api/*` only), request-ID generation/propagation, header hygiene, timeouts, connection pooling, JSON logs. |
| FastAPI | Business logic, RED + business metrics, structured logs, readiness that checks Postgres. |
| Redis | Read-through cache (soft dependency — API degrades to Postgres on cache failure). |
| PostgreSQL | System of record; row-level locking prevents overselling. |

## 3. Security layers

```mermaid
flowchart LR
    subgraph L1[Supply chain]
        s1[SonarQube quality gate]
        s2[OWASP Dependency-Check]
        s3[Trivy fs / IaC / image]
        s4[SBOM CycloneDX]
        s5[Immutable ECR tags + scan on push]
    end
    subgraph L2[Cluster admission]
        a1[Pod Security Standards: restricted]
        a2[ResourceQuota + LimitRange]
        a3[non-root, read-only rootfs,<br/>drop ALL caps, seccomp]
    end
    subgraph L3[Network]
        n1[NetworkPolicy default-deny<br/>+ explicit allows]
        n2[Istio STRICT mTLS]
        n3[AuthorizationPolicy deny-all<br/>+ SPIFFE principal allows]
    end
    subgraph L4[Identity & secrets]
        i1[RBAC: viewer / developer / CI read-only]
        i2[EKS access entries]
        i3[Pod Identity per controller]
        i4[Secrets Manager → External Secrets]
        i5[KMS envelope encryption]
    end
    L1 --> L2 --> L3 --> L4
```

## 4. AWS infrastructure (EKS path)

```mermaid
flowchart TB
    subgraph aws[AWS account · us-east-1]
        r53[Route53 zone<br/>ExternalDNS records]
        ecr[(ECR: api / web / apache-proxy<br/>immutable, scan-on-push)]
        sm[(Secrets Manager<br/>cloudforge/dev/app)]
        s3l[(S3: loki chunks)]
        s3b[(S3: pg backups)]
        kms[KMS: EKS secrets]
        subgraph vpc[VPC 10.40.0.0/16 · 3 AZ]
            subgraph pub[Public subnets /20]
                nlb[NLB → ingress-nginx]
                nlb2[NLB → istio gateway]
                nat[NAT gateway]
            end
            subgraph priv[Private subnets /18]
                cp[EKS control plane ENIs<br/>API: private + CIDR-restricted public]
                ng1[Managed node group: system]
                ng2[Managed node group: apps · Spot]
            end
            s3ep[S3 gateway endpoint]
        end
    end
    nlb --> ng1 & ng2
    ng2 --> nat
    ng2 --> s3ep --> s3l & s3b
    ng2 -->|pull| ecr
    ng1 -->|ESO Pod Identity| sm
    cp --- kms
```

Terraform modules (`infra-terraform/modules`): `vpc`, `security-groups`, `iam`, `eks`, `ecr`,
`s3`, `route53`, composed in `environments/dev`. State lives in S3 with native lockfiles.

## 5. Delivery pipeline

```mermaid
flowchart LR
    A[git push] --> B[Jenkins]
    B --> C[Unit tests<br/>pytest · vitest]
    C --> D[SonarQube<br/>+ quality gate]
    D --> E[OWASP DC ‖ Trivy fs+IaC]
    E --> F[docker build ×3]
    F --> G[Trivy image<br/>+ SBOM]
    G --> H[push registry]
    H --> I[helm lint · render · kubeconform]
    I --> J[yq bump image.tag<br/>gitops/environments/env]
    J --> K[git commit + push]
    K --> L[Argo CD sync]
    L --> M{Rollout strategy}
    M -->|backend| N[Canary 10→25→50→100<br/>Prometheus analysis]
    M -->|frontend| O[Blue/Green<br/>preview + smoke Job<br/>manual promote]
```

## 6. Repository layout ↔ blueprint repositories

The blueprint lists eight repositories; this monorepo keeps them as top-level folders so the
whole platform is reviewable in one place. Splitting later is a `git filter-repo` per folder.

| Blueprint repo | Folder |
|---|---|
| app-frontend | `app-frontend/` |
| app-backend | `app-backend/` (+ `apache-proxy/`) |
| helm-charts | `helm-charts/charts/{frontend,backend,apache-proxy,postgres,redis,platform}` |
| k8s-manifests | `k8s-manifests/` (rendered + Istio/EKS/bootstrap YAML) |
| gitops | `gitops/` (Argo CD projects, ApplicationSets, env values) |
| monitoring | `monitoring/` (Prometheus stack, Loki, Fluent Bit, dashboards-as-code) |
| infra-terraform | `infra-terraform/` |
| infra-ansible | `infra-ansible/` |
