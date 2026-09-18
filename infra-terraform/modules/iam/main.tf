###############################################################################
# IAM: EKS cluster + node roles, and least-privilege roles for in-cluster
# controllers bound through EKS Pod Identity (no OIDC/IRSA annotations needed).
# The eks module creates the pod identity associations from `pod_identity_roles`.
###############################################################################

data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}

locals {
  partition  = data.aws_partition.current.partition
  account_id = data.aws_caller_identity.current.account_id
  pod_identity_trust = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

# ---------------- cluster role ----------------
resource "aws_iam_role" "cluster" {
  name = "${var.name}-eks-cluster"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "cluster" {
  for_each   = toset(["AmazonEKSClusterPolicy", "AmazonEKSVPCResourceController"])
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/${each.value}"
}

# ---------------- node role ----------------
resource "aws_iam_role" "node" {
  name = "${var.name}-eks-node"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "node" {
  for_each = toset([
    "AmazonEKSWorkerNodePolicy",
    "AmazonEKS_CNI_Policy",
    "AmazonEC2ContainerRegistryReadOnly",
    "AmazonSSMManagedInstanceCore", # Session Manager instead of SSH
  ])
  role       = aws_iam_role.node.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/${each.value}"
}

# ---------------- EBS CSI driver ----------------
resource "aws_iam_role" "ebs_csi" {
  name               = "${var.name}-ebs-csi"
  assume_role_policy = local.pod_identity_trust
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# ---------------- AWS Load Balancer Controller ----------------
# Upstream-maintained policy document, pinned to the controller version.
data "http" "lb_controller_policy" {
  url             = "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/${var.lb_controller_version}/docs/install/iam_policy.json"
  request_headers = { Accept = "application/json" }
}

resource "aws_iam_policy" "lb_controller" {
  name   = "${var.name}-aws-lb-controller"
  policy = data.http.lb_controller_policy.response_body
  tags   = var.tags
}

resource "aws_iam_role" "lb_controller" {
  name               = "${var.name}-aws-lb-controller"
  assume_role_policy = local.pod_identity_trust
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "lb_controller" {
  role       = aws_iam_role.lb_controller.name
  policy_arn = aws_iam_policy.lb_controller.arn
}

# ---------------- Cluster Autoscaler ----------------
resource "aws_iam_role" "cluster_autoscaler" {
  name               = "${var.name}-cluster-autoscaler"
  assume_role_policy = local.pod_identity_trust
  tags               = var.tags
}

resource "aws_iam_role_policy" "cluster_autoscaler" {
  name = "cluster-autoscaler"
  role = aws_iam_role.cluster_autoscaler.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "Describe"
        Effect = "Allow"
        Action = [
          "autoscaling:DescribeAutoScalingGroups",
          "autoscaling:DescribeAutoScalingInstances",
          "autoscaling:DescribeLaunchConfigurations",
          "autoscaling:DescribeScalingActivities",
          "autoscaling:DescribeTags",
          "ec2:DescribeImages",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeLaunchTemplateVersions",
          "ec2:GetInstanceTypesFromInstanceRequirements",
          "eks:DescribeNodegroup",
        ]
        Resource = "*"
      },
      {
        Sid    = "ScaleOwnedGroupsOnly"
        Effect = "Allow"
        Action = [
          "autoscaling:SetDesiredCapacity",
          "autoscaling:TerminateInstanceInAutoScalingGroup",
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:ResourceTag/k8s.io/cluster-autoscaler/${var.cluster_name}" = "owned"
          }
        }
      },
    ]
  })
}

# ---------------- ExternalDNS + cert-manager (Route53) ----------------
resource "aws_iam_role" "external_dns" {
  name               = "${var.name}-external-dns"
  assume_role_policy = local.pod_identity_trust
  tags               = var.tags
}

resource "aws_iam_role" "cert_manager" {
  name               = "${var.name}-cert-manager"
  assume_role_policy = local.pod_identity_trust
  tags               = var.tags
}

locals {
  zone_arns = [for id in var.route53_zone_ids : "arn:${local.partition}:route53:::hostedzone/${id}"]
}

resource "aws_iam_role_policy" "external_dns" {
  count = var.enable_dns_policies ? 1 : 0
  name  = "external-dns"
  role  = aws_iam_role.external_dns.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["route53:ChangeResourceRecordSets"]
        Resource = local.zone_arns
      },
      {
        Effect   = "Allow"
        Action   = ["route53:ListHostedZones", "route53:ListResourceRecordSets", "route53:ListTagsForResources"]
        Resource = "*"
      },
    ]
  })
}

resource "aws_iam_role_policy" "cert_manager" {
  count = var.enable_dns_policies ? 1 : 0
  name  = "cert-manager-dns01"
  role  = aws_iam_role.cert_manager.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["route53:GetChange"]
        Resource = "arn:${local.partition}:route53:::change/*"
      },
      {
        Effect   = "Allow"
        Action   = ["route53:ChangeResourceRecordSets", "route53:ListResourceRecordSets"]
        Resource = local.zone_arns
        Condition = {
          "ForAllValues:StringEquals" = { "route53:ChangeResourceRecordSetsRecordTypes" = ["TXT"] }
        }
      },
      {
        Effect   = "Allow"
        Action   = ["route53:ListHostedZonesByName"]
        Resource = "*"
      },
    ]
  })
}

# ---------------- External Secrets Operator ----------------
resource "aws_iam_role" "external_secrets" {
  name               = "${var.name}-external-secrets"
  assume_role_policy = local.pod_identity_trust
  tags               = var.tags
}

resource "aws_iam_role_policy" "external_secrets" {
  name = "read-app-secrets"
  role = aws_iam_role.external_secrets.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret",
        "secretsmanager:ListSecretVersionIds",
      ]
      Resource = "arn:${local.partition}:secretsmanager:${var.region}:${local.account_id}:secret:${var.secrets_prefix}/*"
    }]
  })
}

# ---------------- Loki (S3 chunk storage) ----------------
resource "aws_iam_role" "loki" {
  name               = "${var.name}-loki"
  assume_role_policy = local.pod_identity_trust
  tags               = var.tags
}

resource "aws_iam_role_policy" "loki" {
  count = var.enable_loki_policy ? 1 : 0
  name  = "loki-s3"
  role  = aws_iam_role.loki.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = var.loki_bucket_arn
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = "${var.loki_bucket_arn}/*"
      },
    ]
  })
}

# ---------------- CI (Jenkins) ECR push ----------------
resource "aws_iam_policy" "ci_ecr_push" {
  name        = "${var.name}-ci-ecr-push"
  description = "Push CloudForge images to ECR (attach to the Jenkins instance role or CI user)"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:BatchGetImage",
          "ecr:CompleteLayerUpload",
          "ecr:DescribeImages",
          "ecr:InitiateLayerUpload",
          "ecr:PutImage",
          "ecr:UploadLayerPart",
        ]
        Resource = var.ecr_repository_arns
      },
    ]
  })
  tags = var.tags
}
