data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical's official AWS account

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_instance" "ec2_instance" {
  ami             = data.aws_ami.ubuntu.id
  instance_type   = var.instance_type
  key_name        = aws_key_pair.my_key.key_name
  subnet_id       = var.subnet_id
  vpc_security_group_ids = [var.security_group_id]
  associate_public_ip_address = true
  user_data_replace_on_change = true
  iam_instance_profile = aws_iam_instance_profile.ssm.name

  root_block_device {
    volume_size = var.size
    volume_type = var.volume_type
  }

  tags = {
    Project     = var.project_name
    Environment = var.environment
    name        = "${var.project_name}-${var.environment}-ec2"
  }
  #this block was done by ai
  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    repo_url         = var.repo_url
    repo_branch      = var.repo_branch
    app_user         = var.app_user
    app_home          = var.app_home
    app_subdir       = var.app_subdir
    wsgi_target      = var.wsgi_target
    app_port         = var.app_port
    gunicorn_workers = var.gunicorn_workers
  })

}
resource "tls_private_key" "my_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "my_key" {
  key_name   = "${var.project_name}-${var.environment}-key"
  public_key = tls_private_key.my_key.public_key_openssh
}

resource "local_file" "private_key" {
  content         = tls_private_key.my_key.private_key_pem
  filename        = "${var.project_name}-${var.environment}-key.pem"
  file_permission = "0400"
}

resource "aws_iam_role" "ssm" {
    name = "${var.project_name}-${var.environment}-ssm"
    assume_role_policy = jsonencode({
      Version = "2012-10-17"
      Statement = [{
        Effect    = "Allow"
        Principal = { Service = "ec2.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }]
    })
  }
  resource "aws_iam_role_policy_attachment" "ssm_core" {
    role       = aws_iam_role.ssm.name
    policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }
  resource "aws_iam_instance_profile" "ssm" {
    name = "${var.project_name}-${var.environment}-ssm"
    role = aws_iam_role.ssm.name
  }
