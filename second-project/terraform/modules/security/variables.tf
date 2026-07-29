variable "name_prefix" {
  description = "Prefix for resource names."
  type        = string
}

variable "vpc_id" {
  description = "VPC the security groups belong to."
  type        = string
}

variable "ssh_allowed_cidrs" {
  description = "CIDRs allowed to SSH to the jumpbox."
  type        = list(string)
}

variable "pod_cidr" {
  description = "Pod network CIDR, allowed into the cluster group explicitly."
  type        = string
}
