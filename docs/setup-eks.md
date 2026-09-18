# AWS EKS setup (paid path)

> **Cost warning.** EKS control plane (~$0.10/h), a NAT gateway (~$0.045/h + data), two
> t3.large on-demand system nodes and Spot app nodes, NLBs and EBS volumes are billed while they
> exist — roughly **$8–12/day** with the defaults. Keep demos short and run
> `make eks-down` afterwards. Nothing here is Free Tier.

## Prerequisites

- AWS account + IAM principal with admin rights for the bootstrap (use SSO/role, not root)
- AWS CLI v2 configured (`aws sts get-caller-identity`)
- Terraform ≥ 1.10, kubectl, helm, istioctl (Ansible `workstation.yml` installs them)
- A domain you control (or a sub-domain delegated to Route53)
- The repo on GitHub (`vinitpatil519/CloudForge`, or your fork with URLs replaced — see setup-local.md §4)

## 1. Remote state (one time)

```bash
make tf-bootstrap                         # S3 bucket cloudforge-tfstate-<account>, versioned, KMS, TLS-only
cd infra-terraform/environments/dev
cp backend.hcl.example backend.hcl        # bucket = output state_bucket
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`: `api_allowed_cidrs` (your IP/32), `admin_principal_arns`, `domain`.

## 2. Provision

```bash
make tf-plan          # review: ~90 resources
make tf-apply
terraform output
```

Creates: VPC (3 AZ, public/private, NAT, S3 endpoint, flow logs) · security groups (incl.
Istio webhook 15017) · IAM (cluster/node roles, Pod Identity roles for EBS CSI, LB controller,
Cluster Autoscaler, ExternalDNS, cert-manager, External Secrets, Loki; CI ECR-push policy) ·
EKS (KMS-encrypted secrets, audit logs, access entries, 2 managed node groups, VPC CNI with
NetworkPolicy enforcement, CoreDNS, kube-proxy, Pod Identity agent, EBS CSI) · ECR ×3 · S3 ×2 ·
Route53 zone + CAA · Secrets Manager secret with generated DB/Redis passwords.

Delegate DNS: add the `route53_name_servers` output as NS records at your registrar.

## 3. Wire Terraform outputs into Git

| Output | File | Key |
|---|---|---|
| `vpc_id` | `gitops/addons/aws-load-balancer-controller/values-eks.yaml` | `vpcId` |
| `route53_zone_id` | `gitops/environments/eks/platform.yaml` | `certManager.route53.hostedZoneID` |
| `loki_bucket` | `monitoring/loki/values-eks.yaml` | `loki.storage.bucketNames.*` |
| `ecr_registry` | `gitops/environments/eks/{backend,frontend,apache-proxy}.yaml`, `Jenkinsfile` | `image.repository`, `AWS_ACCOUNT_ID` |
| `domain` | `gitops/environments/eks/frontend.yaml`, `platform.yaml`, `gitops/addons/external-dns/values-eks.yaml` | hosts |

Commit and push.

## 4. Bootstrap the cluster

```bash
make eks-up        # kubeconfig, gp3 StorageClass, Istio (NLB gateway), Argo CD, root apps
kubectl -n argocd get applications -w
```

Argo CD sync order: aws-load-balancer-controller / metrics-server (wave −4) → cert-manager,
Argo Rollouts, VPA, Cluster Autoscaler, External Secrets (−3) → kube-prometheus-stack,
ExternalDNS (−2) → Loki, Fluent Bit, ingress-nginx, ClusterSecretStore (−1) → platform (0) →
postgres, redis (1) → backend (2) → apache-proxy (3) → frontend (4).

## 5. First image build

Point Jenkins at ECR: attach output `ci_ecr_push_policy_arn` to the Jenkins IAM principal,
create the `aws-ci` credential, then run the pipeline with `TARGET_ENV=eks`. Until the first
build, the `1.0.0` tags in `gitops/environments/eks/*.yaml` do not exist — pods will show
`ImagePullBackOff`, which is expected.

## 6. Verify

```bash
kubectl get nodes -L cloudforge.dev/pool,topology.kubernetes.io/zone
kubectl get externalsecrets -A                   # SecretSynced=True
kubectl get certificate -A                       # Ready=True (DNS-01)
scripts/smoke-test.sh https://cloudforge.example.com
```

## 7. Tear down

```bash
make eks-down      # deletes root apps, LoadBalancer Services, PVCs, then terraform destroy
```

The order matters: NLBs and EBS volumes are created by controllers, not Terraform; deleting
them first prevents `DependencyViolation` on VPC destroy and orphaned billing.
