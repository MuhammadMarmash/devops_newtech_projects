output "jumpbox_sg_id" {
  description = "Security group allowing inbound SSH; attach to the jumpbox only."
  value       = aws_security_group.jumpbox.id
}

output "cluster_sg_id" {
  description = "Security group for intra-cluster traffic; attach to every machine."
  value       = aws_security_group.cluster.id
}
