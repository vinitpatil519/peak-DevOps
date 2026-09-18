#!/usr/bin/env bash
# CloudForge on AWS EKS. Prereq: `terraform apply` in infra-terraform/environments/dev.
# COST: EKS + NAT + nodes are billed hourly. Run scripts/teardown-eks.sh when done.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MODE="${MODE:-gitops}"
TF_DIR="$ROOT/infra-terraform/environments/dev"
require aws kubectl istioctl terraform openssl "$HELM"

tf() { terraform -chdir="$TF_DIR" output -raw "$1"; }

log "configuring kubectl"
eval "$(tf kubeconfig_command)"
kubectl config use-context cloudforge-eks >/dev/null

log "default StorageClass gp3"
kubectl apply -f "$ROOT/k8s-manifests/eks/storageclass-gp3.yaml"
kubectl annotate storageclass gp2 storageclass.kubernetes.io/is-default-class=false --overwrite 2>/dev/null || true

log "Istio $ISTIO_VERSION (CNI mode, NLB gateway)"
istioctl install -y -f "$ROOT/k8s-manifests/istio/istio-operator.yaml" -f "$ROOT/k8s-manifests/istio/istio-operator-eks.yaml"
kubectl -n istio-system rollout status deploy/istiod --timeout=5m

ensure_app_namespaces
# On EKS app credentials come from AWS Secrets Manager via External Secrets; only Grafana's is local.
kubectl -n monitoring get secret grafana-admin >/dev/null 2>&1 || \
  kubectl -n monitoring create secret generic grafana-admin \
    --from-literal=admin-user=admin --from-literal=admin-password="$(rand 24)"
kubectl apply -f "$ROOT/k8s-manifests/bootstrap/jenkins-deployer.yaml" >/dev/null

log "values that come from Terraform outputs — commit these to Git before syncing:"
echo "  gitops/addons/aws-load-balancer-controller/values-eks.yaml  vpcId: $(tf vpc_id)"
echo "  gitops/environments/eks/platform.yaml                       hostedZoneID: $(tf route53_zone_id)"
echo "  monitoring/loki/values-eks.yaml                             bucketNames: $(tf loki_bucket)"
echo "  gitops/environments/eks/*.yaml                              image.repository: $(tf ecr_registry)/cloudforge/<name>"

if [[ "$MODE" == "gitops" ]]; then
  install_argocd eks
  kubectl apply -n argocd -f "$ROOT/gitops/root-app.yaml"
  kubectl apply -n argocd -f "$ROOT/gitops/root-app-eks.yaml"
  log "Argo CD is reconciling. kubectl -n argocd get applications -w"
else
  warn "MODE=helm on EKS installs common add-ons only; AWS add-ons (LB controller, ESO, ExternalDNS, CA) need Argo CD or manual Helm installs"
  install_addons eks
  install_apps eks
fi

log "NS delegation for your domain: $(terraform -chdir="$TF_DIR" output -json route53_name_servers)"
