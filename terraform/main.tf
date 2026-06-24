terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}
provider "aws" {
  region = var.region
}
module "vpc_module" {
  source       = "./modules/vpc"
  project_name = var.project_name
  environment  = var.environment
}

module "security_group_module" {
  source       = "./modules/security_group"
  vpc_id       = module.vpc_module.vpc_id
  my_ip        = var.my_ip
  project_name = var.project_name
  environment  = var.environment
}

module "ec2_module" {
  source            = "./modules/ec2"
  security_group_id = module.security_group_module.security_group_id
  subnet_id         = module.vpc_module.public_subnet_id
  project_name      = var.project_name
  environment       = var.environment
}

#making elastic ip for ec2 instance
resource "aws_eip" "ec2_eip" {
  domain = "vpc"
  tags = {
    Name        = "${var.project_name}-${var.environment}-ec2-eip"
    Environment = var.environment
    Project     = var.project_name
  }
}

resource "aws_eip_association" "ec2_eip_assoc" {
  instance_id   = module.ec2_module.instance_id
  allocation_id = aws_eip.ec2_eip.id
}
