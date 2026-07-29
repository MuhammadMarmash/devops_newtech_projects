output "jumpbox_instance_profile_name" {
  description = "Instance profile for the jumpbox (SSM read and write)."
  value       = aws_iam_instance_profile.jumpbox.name
}

output "node_instance_profile_name" {
  description = "Instance profile for the server and workers (SSM read only)."
  value       = aws_iam_instance_profile.node.name
}

output "jumpbox_role_arn" {
  description = "ARN of the jumpbox role."
  value       = aws_iam_role.jumpbox.arn
}

output "node_role_arn" {
  description = "ARN of the node role."
  value       = aws_iam_role.node.arn
}
