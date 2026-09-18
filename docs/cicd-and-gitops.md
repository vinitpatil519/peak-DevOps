# CI/CD and GitOps

## Principles

1. **CI builds, Git decides, Argo CD deploys.** Jenkins never runs `kubectl apply` or `helm
   upgrade` against a cluster. Its only write is a Git commit that changes an image tag.
2. **Immutable artifacts.** Tag = `<git sha>-<build number>`; ECR repositories are
   `IMMUTABLE`, so a tag always means the same bytes.
3. **Shift-left security gates** fail the build before an image exists in a registry.
4. **One chart, many environments.** `helm-charts/` is environment-agnostic;
   `gitops/environments/<env>/<chart>.yaml` holds the differences.

## Jenkins stages (`Jenkinsfile`)

| Stage | Tooling | Fails the build when |
|---|---|---|
| Checkout | git | commit message has `[skip ci]` (bot promotion commits) |
| Unit tests (parallel) | ruff + pytest (coverage XML, JUnit) · eslint + vitest + vite build | any test/lint fails |
| SonarQube | `sonar-scanner-cli` container per module | — |
| Quality gate | `waitForQualityGate` | gate is red (coverage, bugs, vulnerabilities, hotspots) |
| OWASP Dependency-Check | `owasp/dependency-check` | CVSS ≥ 9 dependency |
| Trivy fs + IaC | `trivy fs` (vuln, secret), `trivy config` (Terraform, Helm, Dockerfile, K8s) | HIGH/CRITICAL finding |
| Build images | `docker build` ×3 in parallel with OCI labels | build error |
| Image scan + SBOM | `trivy image`, CycloneDX SBOM archived | fixable HIGH/CRITICAL CVE |
| Push | docker push (main only); ECR login for `eks` | — |
| Helm lint + render | helm lint, `scripts/render-manifests.sh`, kubeconform (+ CRD schemas) | invalid chart/manifest |
| Promote via GitOps | `yq` edits `image.tag` + `image.repository`, `git push` | — |

## GitOps structure

```
gitops/
├── root-app.yaml                 # app-of-apps (all clusters)
├── root-app-eks.yaml             # extra root for AWS-only objects
├── argocd/
│   ├── projects/cloudforge.yaml  # AppProjects: cloudforge (apps), cloudforge-platform (add-ons)
│   ├── applicationsets/cloudforge-apps.yaml   # cluster × chart matrix, sync waves 0-4
│   ├── addons/addons.yaml        # upstream Helm add-ons (+ EKS-only set)
│   └── argocd-cm-patch.yaml      # Argo CD settings + RBAC (applied by bootstrap)
├── argocd-eks/secret-store-app.yaml
├── addons/<addon>/values[-env].yaml
└── environments/{local,eks}/<chart>.yaml
```

Clusters opt in with a label on their Argo CD cluster Secret: `cloudforge.dev/env=local|eks`.
Adding a `prod` cluster = new values folder + labelled cluster secret; no new Application YAML.

### Drift and ownership rules

`ignoreDifferences` lets controllers own fields without Argo CD fighting them:

- `spec.replicas` on Deployments/Rollouts — HPA owns it.
- VirtualService route weights and DestinationRule subset labels — Argo Rollouts owns them mid-canary.
- `rollouts-pod-template-hash` on Services — Argo Rollouts owns blue/green selectors.

### Promotion between environments

`local` and `eks` are independent targets here. For a dev → staging → prod chain, have Jenkins
promote to `dev` automatically and open a PR that copies the tag to `staging`/`prod`
values; the PR review is the change-approval record, and the AppProject sync window blocks
weekend auto-syncs for `*-prod` apps.

## Rollback

| Situation | Action |
|---|---|
| Canary fails analysis | Automatic: Argo Rollouts sets weight back to 0 and marks Degraded. |
| Bad version fully rolled out | `git revert <promotion commit>` → Argo CD syncs the previous tag. |
| Frontend just promoted | `kubectl argo rollouts undo frontend -n frontend` within `scaleDownDelaySeconds`, then revert in Git. |
| Emergency, Git unavailable | `argocd app rollback backend-local <id>` (disable auto-sync first). |
