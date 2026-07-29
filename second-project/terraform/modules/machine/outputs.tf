output "id" {
  description = "Instance ID."
  value       = aws_instance.this.id
}

output "name" {
  description = "Machine name."
  value       = var.name
}

output "private_ip" {
  description = "Private IP. This is the address all cluster components use."
  value       = aws_instance.this.private_ip
}

output "public_ip" {
  description = "Public IP, or empty for private machines."
  value       = aws_instance.this.public_ip
}

# Phase 5 pod routes target an ENI, not an instance.
output "primary_network_interface_id" {
  description = "Primary ENI ID."
  value       = aws_instance.this.primary_network_interface_id
}
