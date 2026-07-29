terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

provider "aws" {
  region = "eu-north-1"
}

locals {
  ssh_user     = "admin"
  ssh_key_name = "kubernetes-hard-way"
}

locals {
  machines = [
    {
      name           = "jumpbox"
      description    = "Administration host"
      instance_type  = "t3.micro"
      volume_size_gb = 10
    },
    {
      name           = "server"
      description    = "Kubernetes server"
      instance_type  = "t3.small"
      volume_size_gb = 20
    },
    {
      name           = "node-0"
      description    = "Kubernetes worker node"
      instance_type  = "t3.small"
      volume_size_gb = 20
    },
    {
      name           = "node-1"
      description    = "Kubernetes worker node"
      instance_type  = "t3.small"
      volume_size_gb = 20
    }
  ]
}

resource "tls_private_key" "ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "ssh" {
  key_name   = local.ssh_key_name
  public_key = tls_private_key.ssh.public_key_openssh
}

resource "local_sensitive_file" "ssh_private_key" {
  filename        = "${path.module}/${local.ssh_key_name}.pem"
  content         = tls_private_key.ssh.private_key_pem
  file_permission = "0600"
}

resource "aws_security_group" "ssh" {
  name        = "${local.ssh_key_name}-ssh"
  description = "Allow SSH access to the machines"

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "private_network" {
  name   = "${local.ssh_key_name}-private"
  description = "k8s internal cluster traffic"

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
  }
}

resource "aws_instance" "machines" {
  count = length(local.machines)
  //the ami is for Debian 13
  ami                         = "ami-01ef747f983799d6f"
  instance_type               = local.machines[count.index].instance_type
  key_name                    = aws_key_pair.ssh.key_name
  vpc_security_group_ids      = [aws_security_group.ssh.id, aws_security_group.private_network.id]
  associate_public_ip_address = true

  root_block_device {
    volume_size = local.machines[count.index].volume_size_gb
    volume_type = "gp3"
  }

  tags = {
    Name        = local.machines[count.index].name
    Description = local.machines[count.index].description
  }
}

output "ssh_private_key_path" {
  value = local_sensitive_file.ssh_private_key.filename
}

output "machine_connections" {
  value = [
    for machine in aws_instance.machines : {
      name        = machine.tags.Name
      id          = machine.id
      description = machine.tags.Description
      public_ip   = machine.public_ip
      ssh_command = "ssh -i ${local_sensitive_file.ssh_private_key.filename} ${local.ssh_user}@${machine.public_ip}"
    }
  ]
}
