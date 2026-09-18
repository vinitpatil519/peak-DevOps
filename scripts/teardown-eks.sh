#!/usr/bin/env bash
# Tear down the EKS environment in the right order so AWS load balancers and volumes
# created by controllers do not block VPC deletion or keep billing.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require kubectl terraform
TF_DIR="$ROOT/infra-terraform/environments/dev"

echo "This destroys the CloudForge EKS cluster, VPC, ECR images, buckets and DNS zone (demo_mode)."
read -r -p "Type the cluster name 'cloudforge-dev' to confirm: " ans
[[ "$ans" == "cloudforge-dev" ]] || { echo "aborted"; exit 1; }

log "removing Argo CD root apps (stops re-creation)"
kubectl -n argocd delete application cloudforge-root cloudforge-root-eks --ignore-not-found --wait=true || true

log "deleting LoadBalancer Services and Ingresses (releases NLBs)"
kubectl delete ingress --all -A --ignore-not-found || true
kubectl get svc -A -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' |
  while read -r ns name; do kubectl -n "$ns" delete svc "$name" --ignore-not-found; done

log "deleting PVCs (releases EBS volumes)"
kubectl delete pvc --all -A --ignore-not-found --wait=false || true
sleep 60

log "terraform destroy"
terraform -chdir="$TF_DIR" destroy -auto-approve
