output "cluster_security_group_id" {
  description = "Additional control plane security group"
  value       = aws_security_group.cluster.id
}

output "node_security_group_id" {
  description = "Worker node security group"
  value       = aws_security_group.node.id
}
