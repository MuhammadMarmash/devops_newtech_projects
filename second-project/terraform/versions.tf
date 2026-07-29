terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
  }
}

provider "aws" {
  region = var.region

  # Applied to every taggable resource, so modules only tag what needs a Name.
  default_tags {
    tags = {
      Project   = "kubernetes-the-hard-way"
      ManagedBy = "terraform"
      Phase     = "1"
    }
  }
}
