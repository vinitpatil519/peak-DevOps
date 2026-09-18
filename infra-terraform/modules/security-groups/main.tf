###############################################################################
# Security groups for the EKS control plane and worker nodes.
# EKS also creates its own cluster SG; these add explicit, least-privilege rules
# including the ports Istio and add-on webhooks need.
###############################################################################

resource "aws_security_group" "cluster" {
  name        = "${var.name}-cluster"
  description = "EKS control plane additional security group"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.name}-cluster" })
}

resource "aws_security_group" "node" {
  name        = "${var.name}-node"
  description = "EKS worker nodes"
  vpc_id      = var.vpc_id
  tags = merge(var.tags, {
    Name                                        = "${var.name}-node"
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
  })
}

# ---- control plane <-> nodes ----
resource "aws_vpc_security_group_ingress_rule" "cluster_from_nodes_https" {
  security_group_id            = aws_security_group.cluster.id
  referenced_security_group_id = aws_security_group.node.id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  description                  = "Nodes to API server"
}

resource "aws_vpc_security_group_egress_rule" "cluster_to_nodes" {
  security_group_id            = aws_security_group.cluster.id
  referenced_security_group_id = aws_security_group.node.id
  ip_protocol                  = "tcp"
  from_port                    = 0
  to_port                      = 65535
  description                  = "API server to kubelets, webhooks and metrics"
}

locals {
  # Ports the control plane must reach on nodes/pods:
  #   443/9443/8443 admission webhooks (LB controller, cert-manager, ingress-nginx, ESO)
  #   10250 kubelet, 15017 istiod sidecar-injector/validation webhook, 4443 metrics-server
  control_plane_to_node_ports = {
    kubelet            = 10250
    webhook_https      = 443
    webhook_9443       = 9443
    webhook_8443       = 8443
    istiod_webhook     = 15017
    metrics_server_api = 4443
    cert_manager       = 10260
  }
}

resource "aws_vpc_security_group_ingress_rule" "node_from_cluster" {
  for_each                     = local.control_plane_to_node_ports
  security_group_id            = aws_security_group.node.id
  referenced_security_group_id = aws_security_group.cluster.id
  ip_protocol                  = "tcp"
  from_port                    = each.value
  to_port                      = each.value
  description                  = "Control plane to ${each.key}"
}

# ---- node <-> node (pod-to-pod, Istio mTLS, DNS) ----
resource "aws_vpc_security_group_ingress_rule" "node_to_node" {
  security_group_id            = aws_security_group.node.id
  referenced_security_group_id = aws_security_group.node.id
  ip_protocol                  = "-1"
  description                  = "Node to node / pod to pod (fine-grained control via NetworkPolicy + Istio)"
}

# Load balancer traffic to ingress-nginx pods (NLB, IP targets) from within the VPC.
resource "aws_vpc_security_group_ingress_rule" "node_from_vpc_lb" {
  for_each          = toset(["80", "443"])
  security_group_id = aws_security_group.node.id
  cidr_ipv4         = var.vpc_cidr
  ip_protocol       = "tcp"
  from_port         = tonumber(each.value)
  to_port           = tonumber(each.value)
  description       = "NLB health checks / traffic to ingress on ${each.value}"
}

resource "aws_vpc_security_group_egress_rule" "node_all" {
  security_group_id = aws_security_group.node.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "Egress via NAT (image pulls, AWS APIs)"
}
