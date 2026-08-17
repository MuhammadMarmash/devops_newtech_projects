resource "aws_instance" "this" {
  ami                         = var.ami_id
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = var.security_group_ids
  key_name                    = var.key_name
  iam_instance_profile        = var.iam_instance_profile
  associate_public_ip_address = var.associate_public_ip
  source_dest_check           = var.source_dest_check
  user_data                   = var.user_data

  # Default is false, which writes the new user_data into state and does nothing to the
  # machine — so a Phase 4 bootstrap edit would look applied while never having run.
  user_data_replace_on_change = true

  root_block_device {
    volume_size           = var.volume_size_gb
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  # IMDSv2 required. Phase 4's user_data pulls the bootstrap token using instance-profile
  # credentials from IMDS, and IMDSv1 is the classic SSRF-to-credential-theft path.
  # hop_limit 2 so containerised workloads can still reach IMDS.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  tags = {
    Name = var.name
  }

  timeouts {
    create = "5m"
  }
}
