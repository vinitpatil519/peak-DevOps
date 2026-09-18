# Security model

## Controls by layer

| Layer | Control | Where |
|---|---|---|
| Code | SonarQube quality gate, ruff (incl. bandit `S` rules), eslint | Jenkinsfile, `pyproject.toml` |
| Dependencies | OWASP Dependency-Check (fail CVSS ≥ 9), Trivy fs, Renovate | Jenkinsfile, `renovate.json` |
| Secrets in Git | Trivy secret scanner, gitleaks pre-commit, `.gitignore` for tfvars/.env | `.pre-commit-config.yaml` |
| IaC | Trivy config (Terraform, Helm, Dockerfile, K8s) | `security/trivy.yaml` |
| Images | Multi-stage, slim bases, non-root UID, no shell tools added, OCI labels; Trivy image scan; CycloneDX SBOM; ECR immutable tags + scan on push | Dockerfiles, Jenkinsfile, `modules/ecr` |
| Admission | Pod Security Standards `restricted` enforced on app namespaces (possible thanks to Istio CNI) | `charts/platform` |
| Pod hardening | `runAsNonRoot`, fixed UIDs, `readOnlyRootFilesystem`, `drop: [ALL]`, `seccompProfile: RuntimeDefault`, `automountServiceAccountToken: false` | every chart |
| Resource abuse | ResourceQuota + LimitRange per namespace; requests/limits on every container | `charts/platform` |
| Network (L3/4) | default-deny NetworkPolicy per namespace + explicit allows (DNS, istiod, tier-to-tier, monitoring) | platform + each chart |
| Network (L7 / identity) | Istio STRICT mTLS mesh-wide; AuthorizationPolicy default-deny + ALLOW by SPIFFE principal and path | platform + each chart |
| Edge | TLS via cert-manager (Let's Encrypt, DNS-01 on EKS), HSTS, security headers, rate limit, snippets disabled, CAA record | ingress, `modules/route53` |
| Access | RBAC roles: viewer, developer (no Secrets, no RBAC edits), CI read-only; EKS access entries; Argo CD project roles | `charts/platform/templates/rbac.yaml`, `modules/eks` |
| Cloud IAM | EKS Pod Identity per controller with least-privilege policies; nodes IMDSv2 hop-limit 1 | `modules/iam`, `modules/eks` |
| Secrets | Local: generated at bootstrap, never in Git. EKS: Terraform-generated in Secrets Manager → External Secrets; KMS envelope encryption of etcd secrets | `scripts/lib.sh`, `modules/eks` |
| Data | Postgres SCRAM auth + data checksums; S3 SSE-KMS, TLS-only policy, public access blocked | charts/postgres, `modules/s3` |
| Audit | EKS control-plane audit logs → CloudWatch; VPC flow logs (REJECT) | `modules/eks`, `modules/vpc` |

## Traffic allowed (everything else is denied twice: NetworkPolicy and AuthorizationPolicy)

| From | To | Port | Identity check |
|---|---|---|---|
| ingress-nginx, istio-ingressgateway | frontend | 8080 | `ns/ingress-nginx/sa/ingress-nginx`, `ns/istio-system/sa/istio-ingressgateway-service-account` |
| frontend | apache-proxy | 8080 | `ns/frontend/sa/frontend`, path `/api/*` |
| apache-proxy | backend-api | 8000 | `ns/backend/sa/apache-proxy`, GET/POST `/api/*` |
| backend-api | postgres / redis | 5432 / 6379 | `ns/backend/sa/backend-api` |
| postgres-backup Job | postgres | 5432 | `ns/database/sa/postgres-backup` |
| monitoring | sidecar merged metrics / exporters | 15020 / 9117, 9121, 9187 | port-level PERMISSIVE for exporters only |

## Known trade-offs (documented, not hidden)

- **ingress-nginx retirement:** the community controller reached end of maintenance in March
  2026. It stays because the blueprint requires NGINX Ingress; the Istio Gateway is already
  wired as the migration target (Gateway API).
- **Docker socket in Jenkins** (local lab only) is root-equivalent on the host. Use Kubernetes
  agents or rootless BuildKit for shared CI.
- **In-cluster Postgres/Redis** are single-replica for cost. Production on AWS: RDS/Aurora
  Multi-AZ and ElastiCache, or an operator (CloudNativePG).
- **Public EKS endpoint** is enabled but CIDR-restricted; set `endpoint_public_access = false`
  when you have VPN/bastion access.
