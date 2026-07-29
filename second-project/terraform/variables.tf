variable "region" {
  description = "AWS region for all resources."
  type        = string
  default     = "eu-north-1"
}

variable "availability_zone" {
  description = "Single AZ hosting both subnets. Multi-AZ buys no availability while the control plane is one instance."
  type        = string
  default     = "eu-north-1a"
}

variable "name_prefix" {
  description = "Prefix for resource names and the SSH key file."
  type        = string
  default     = "kthw"
}

variable "vpc_cidr" {
  description = "CIDR of the dedicated VPC. Must not overlap pod_cidr or service_cidr."
  type        = string
  default     = "10.240.0.0/16"
}

variable "public_subnet_cidr" {
  description = "Public subnet: jumpbox and NAT gateway."
  type        = string
  default     = "10.240.0.0/24"
}

variable "private_subnet_cidr" {
  description = "Private subnet: server and workers. No public IPs."
  type        = string
  default     = "10.240.1.0/24"
}

variable "pod_cidr" {
  description = "Pod network. Used now for a security group ingress rule; becomes --cluster-cidr in Phase 5."
  type        = string
  default     = "10.200.0.0/16"
}

variable "service_cidr" {
  description = "Service network. Recorded for Phase 2 apiserver certificate SANs (ClusterIP 10.32.0.1)."
  type        = string
  default     = "10.32.0.0/24"
}

variable "cluster_domain" {
  description = "Domain used to build FQDNs in the inventory output."
  type        = string
  default     = "kubernetes.local"
}

variable "worker_count" {
  description = "Number of worker nodes. Workers are keyed by name, so changing this adds or removes only the affected nodes."
  type        = number
  default     = 2

  validation {
    condition     = var.worker_count >= 1 && var.worker_count <= 10
    error_message = "worker_count must be between 1 and 10."
  }
}

variable "jumpbox_instance_type" {
  description = "Instance type for the jumpbox."
  type        = string
  default     = "t3.micro"
}

variable "server_instance_type" {
  description = "Instance type for the control plane."
  type        = string
  default     = "t3.small"
}

variable "worker_instance_type" {
  description = "Instance type for worker nodes."
  type        = string
  default     = "t3.small"
}

variable "jumpbox_volume_size_gb" {
  description = "Root volume size for the jumpbox."
  type        = number
  default     = 10
}

variable "node_volume_size_gb" {
  description = "Root volume size for the server and each worker."
  type        = number
  default     = 20
}

variable "ssh_allowed_cidrs" {
  description = "CIDRs allowed to SSH to the jumpbox. Narrow this to your own IP when possible."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "ssm_path_prefix" {
  description = "SSM parameter path prefix. IAM policies grant access to everything beneath it."
  type        = string
  default     = "/kthw"

  validation {
    condition     = can(regex("^/[a-zA-Z0-9_.-]+$", var.ssm_path_prefix))
    error_message = "ssm_path_prefix must start with / and contain no trailing slash."
  }
}
