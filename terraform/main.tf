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
