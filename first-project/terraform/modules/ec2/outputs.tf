output "instance_id" {
  description = "The ID of the EC2 instance"
  value       = aws_instance.ec2_instance.id
}

output "public_ip" {
  description = "The public IP address of the EC2 instance"
  value       = aws_instance.ec2_instance.public_ip
}

output "elastic_ip" {
  description = "The Elastic IP attached to the instance (stable across rebuilds)"
  value       = aws_eip.ec2_eip.public_ip
}
