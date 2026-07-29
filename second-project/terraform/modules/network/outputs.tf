output "vpc_id" {
  description = "ID of the VPC."
  value       = aws_vpc.this.id
}

output "public_subnet_id" {
  description = "ID of the public subnet (jumpbox, NAT)."
  value       = aws_subnet.public.id
}

output "private_subnet_id" {
  description = "ID of the private subnet (server, workers)."
  value       = aws_subnet.private.id
}

# Phase 5 programs pod-CIDR routes into this table.
output "private_route_table_id" {
  description = "ID of the private route table."
  value       = aws_route_table.private.id
}

output "nat_gateway_id" {
  description = "ID of the NAT gateway."
  value       = aws_nat_gateway.this.id
}

# Instances in the private subnet must depend on this so user_data never races the
# NAT route. Exposed as an explicit handle for callers to depend_on.
output "private_route_table_association_id" {
  description = "ID of the private subnet route table association."
  value       = aws_route_table_association.private.id
}
