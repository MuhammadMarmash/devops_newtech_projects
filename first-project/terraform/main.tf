terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  backend "s3" {
      bucket       = "mini-project1-tfstate-284483510847"
      key          = "mini-project1/terraform.tfstate"
      region       = "eu-north-1"
      encrypt      = true
      use_lockfile = true
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
