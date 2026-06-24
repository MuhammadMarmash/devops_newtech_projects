output "ec2_public_ip" {
  value = module.ec2_module.public_ip
}

output "ec2_instance_id" {
  value = module.ec2_module.instance_id
}

output "ec2_elastic_ip" {
  description = "Stable public IP (Elastic IP) — use this for the EC2_HOST secret"
  value       = aws_eip.ec2_eip.public_ip
}
