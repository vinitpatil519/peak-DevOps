# k8s-manifests

Plain Kubernetes YAML for CloudForge.

| Path | What | How it is produced |
|---|---|---|
| `rendered/local/`, `rendered/eks/` | Every app/platform object (Namespaces, PSS labels, quotas, NetworkPolicies, RBAC, ConfigMaps, Secrets refs, Deployments/Rollouts, StatefulSets, Services, Ingress, HPA, PDB, VPA, Istio Gateway/VirtualService/DestinationRule/PeerAuthentication/AuthorizationPolicy, ServiceMonitors, PrometheusRules, Grafana dashboards) | `scripts/render-manifests.sh` from `helm-charts/` + `gitops/environments/<env>/`. Do not edit by hand. |
| `istio/` | IstioOperator install profiles (base + EKS overlay) | hand-written |
| `eks/` | EKS-only cluster objects (gp3 StorageClass) | hand-written |
| `bootstrap/` | Jenkins identity, reference Secret shapes | hand-written |

Apply without Helm/Argo CD (namespaces first, CRDs from add-ons must exist):

```bash
kubectl apply -k k8s-manifests/rendered/local
```
