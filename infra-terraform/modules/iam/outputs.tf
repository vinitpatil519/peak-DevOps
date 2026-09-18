output "cluster_role_arn" {
  description = "EKS cluster IAM role"
  value       = aws_iam_role.cluster.arn
}

output "node_role_arn" {
  description = "EKS node IAM role"
  value       = aws_iam_role.node.arn
}

output "ci_ecr_push_policy_arn" {
  description = "Attach to the Jenkins role/user"
  value       = aws_iam_policy.ci_ecr_push.arn
}

# Consumed by the eks module to create aws_eks_pod_identity_association resources.
output "pod_identity_roles" {
  description = "Controller service accounts -> IAM roles"
  value = {
    ebs-csi = {
      namespace       = "kube-system"
      service_account = "ebs-csi-controller-sa"
      role_arn        = aws_iam_role.ebs_csi.arn
    }
    aws-load-balancer-controller = {
      namespace       = "kube-system"
      service_account = "aws-load-balancer-controller"
      role_arn        = aws_iam_role.lb_controller.arn
    }
    cluster-autoscaler = {
      namespace       = "kube-system"
      service_account = "cluster-autoscaler"
      role_arn        = aws_iam_role.cluster_autoscaler.arn
    }
    external-dns = {
      namespace       = "external-dns"
      service_account = "external-dns"
      role_arn        = aws_iam_role.external_dns.arn
    }
    cert-manager = {
      namespace       = "cert-manager"
      service_account = "cert-manager"
      role_arn        = aws_iam_role.cert_manager.arn
    }
    external-secrets = {
      namespace       = "external-secrets"
      service_account = "external-secrets"
      role_arn        = aws_iam_role.external_secrets.arn
    }
    loki = {
      namespace       = "monitoring"
      service_account = "loki"
      role_arn        = aws_iam_role.loki.arn
    }
  }
}
