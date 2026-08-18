terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
  }
}

provider "aws" {
  region = var.region

  # The AWS SDK's own default is 25 retries (~1 hour) on retryable errors like
  # InsufficientInstanceCapacity. A resource-level `timeouts` block cannot override this —
  # only the provider's own max_retries can.
  max_retries = 3

  # Applied to every taggable resource, so modules only tag what needs a Name.
  default_tags {
    tags = {
      Project   = "kubernetes-the-hard-way"
      ManagedBy = "terraform"
      Phase     = "1"
    }
  }
}
