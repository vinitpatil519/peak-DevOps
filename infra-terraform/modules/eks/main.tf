###############################################################################
# EKS: control plane (private+public endpoint, KMS-encrypted secrets, audit logs,
# API-mode access entries), managed node groups, core add-ons (VPC CNI with
# NetworkPolicy enforcement, CoreDNS, kube-proxy, Pod Identity agent, EBS CSI)
# and Pod Identity associations for in-cluster controllers.
###############################################################################

data "aws_partition" "current" {}

# ---------------- secrets envelope encryption ----------------
resource "aws_kms_key" "eks" {
  description             = "EKS secrets envelope encryption for ${var.cluster_name}"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  tags                    = var.tags
}

resource "aws_kms_alias" "eks" {
  name          = "alias/${var.cluster_name}-eks"
  target_key_id = aws_kms_key.eks.key_id
}

resource "aws_cloudwatch_log_group" "cluster" {
  # EKS writes control-plane logs here; pre-create to control retention.
  name              = "/aws/eks/${var.cluster_name}/cluster"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

# ---------------- control plane ----------------
resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  version  = var.kubernetes_version
  role_arn = var.cluster_role_arn

  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = true
  }

  vpc_config {
    subnet_ids              = var.private_subnet_ids
    security_group_ids      = [var.cluster_security_group_id]
    endpoint_private_access = true
    endpoint_public_access  = var.endpoint_public_access
    public_access_cidrs     = var.endpoint_public_access_cidrs
  }

  kubernetes_network_config {
    ip_family         = "ipv4"
    service_ipv4_cidr = var.service_cidr
  }

  encryption_config {
    resources = ["secrets"]
    provider {
      key_arn = aws_kms_key.eks.arn
    }
  }

  upgrade_policy {
    # STANDARD avoids paid extended support; plan upgrades within the standard window.
    support_type = "STANDARD"
  }

  tags       = var.tags
  depends_on = [aws_cloudwatch_log_group.cluster]
}

# ---------------- access entries (who can use kubectl) ----------------
resource "aws_eks_access_entry" "admins" {
  for_each      = toset(var.admin_principal_arns)
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value
  type          = "STANDARD"
  tags          = var.tags
}

resource "aws_eks_access_policy_association" "admins" {
  for_each      = toset(var.admin_principal_arns)
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value
  policy_arn    = "arn:${data.aws_partition.current.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  access_scope {
    type = "cluster"
  }
  depends_on = [aws_eks_access_entry.admins]
}

# Developers map to the Kubernetes group bound by charts/platform RBAC (cloudforge:developers).
resource "aws_eks_access_entry" "developers" {
  for_each          = toset(var.developer_principal_arns)
  cluster_name      = aws_eks_cluster.this.name
  principal_arn     = each.value
  type              = "STANDARD"
  kubernetes_groups = ["cloudforge:developers"]
  tags              = var.tags
}

# ---------------- managed node groups ----------------
resource "aws_launch_template" "node" {
  for_each    = var.node_groups
  name_prefix = "${var.cluster_name}-${each.key}-"

  vpc_security_group_ids = [var.node_security_group_id, aws_eks_cluster.this.vpc_config[0].cluster_security_group_id]

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2 only
    http_put_response_hop_limit = 1          # pods cannot reach node IMDS credentials
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = each.value.disk_size
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  monitoring {
    enabled = true
  }

  tag_specifications {
    resource_type = "instance"
    tags          = merge(var.tags, { Name = "${var.cluster_name}-${each.key}" })
  }

  tags = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_eks_node_group" "this" {
  for_each        = var.node_groups
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = each.key
  node_role_arn   = var.node_role_arn
  subnet_ids      = var.private_subnet_ids
  ami_type        = each.value.ami_type
  capacity_type   = each.value.capacity_type
  instance_types  = each.value.instance_types

  scaling_config {
    min_size     = each.value.min_size
    max_size     = each.value.max_size
    desired_size = each.value.desired_size
  }

  update_config {
    max_unavailable_percentage = 33
  }

  launch_template {
    id      = aws_launch_template.node[each.key].id
    version = aws_launch_template.node[each.key].latest_version
  }

  labels = merge({ "cloudforge.dev/pool" = each.key }, each.value.labels)

  dynamic "taint" {
    for_each = each.value.taints
    content {
      key    = taint.value.key
      value  = taint.value.value
      effect = taint.value.effect
    }
  }

  tags = merge(var.tags, {
    "k8s.io/cluster-autoscaler/enabled"             = "true"
    "k8s.io/cluster-autoscaler/${var.cluster_name}" = "owned"
  })

  lifecycle {
    # Cluster Autoscaler owns desired_size after creation.
    ignore_changes = [scaling_config[0].desired_size]
  }

  depends_on = [aws_eks_addon.pre_compute]
}

# ---------------- add-ons ----------------
data "aws_eks_addon_version" "latest" {
  for_each           = toset(["vpc-cni", "eks-pod-identity-agent", "kube-proxy", "coredns", "aws-ebs-csi-driver"])
  addon_name         = each.value
  kubernetes_version = aws_eks_cluster.this.version
  most_recent        = true
}

# Networking add-ons must exist before nodes join.
resource "aws_eks_addon" "pre_compute" {
  for_each                    = toset(["vpc-cni", "eks-pod-identity-agent", "kube-proxy"])
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = each.value
  addon_version               = data.aws_eks_addon_version.latest[each.value].version
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"
  # VPC CNI network policy agent enforces Kubernetes NetworkPolicy objects.
  configuration_values = each.value == "vpc-cni" ? jsonencode({
    enableNetworkPolicy = "true"
    env = {
      ENABLE_PREFIX_DELEGATION = "true" # more pod IPs per node
      WARM_PREFIX_TARGET       = "1"
    }
  }) : null
  tags = var.tags
}

resource "aws_eks_addon" "post_compute" {
  for_each                    = toset(["coredns", "aws-ebs-csi-driver"])
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = each.value
  addon_version               = data.aws_eks_addon_version.latest[each.value].version
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"

  dynamic "pod_identity_association" {
    for_each = each.value == "aws-ebs-csi-driver" ? [var.pod_identity_roles["ebs-csi"]] : []
    content {
      role_arn        = pod_identity_association.value.role_arn
      service_account = pod_identity_association.value.service_account
    }
  }

  tags       = var.tags
  depends_on = [aws_eks_node_group.this]
}

# ---------------- Pod Identity for controllers installed by Argo CD ----------------
resource "aws_eks_pod_identity_association" "this" {
  for_each        = { for k, v in var.pod_identity_roles : k => v if k != "ebs-csi" }
  cluster_name    = aws_eks_cluster.this.name
  namespace       = each.value.namespace
  service_account = each.value.service_account
  role_arn        = each.value.role_arn
  tags            = var.tags
  depends_on      = [aws_eks_addon.pre_compute]
}
