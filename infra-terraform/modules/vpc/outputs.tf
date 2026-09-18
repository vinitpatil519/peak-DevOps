output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "VPC CIDR block"
  value       = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  description = "Public subnet IDs"
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "Private subnet IDs"
  value       = aws_subnet.private[*].id
}

output "azs" {
  description = "Availability zones in use"
  value       = local.azs
}

output "nat_public_ips" {
  description = "Egress IPs of the NAT gateways (allow-list these at third parties)"
  value       = aws_eip.nat[*].public_ip
}
