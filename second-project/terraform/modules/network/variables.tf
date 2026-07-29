variable "name_prefix" {
  description = "Prefix for resource names."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR of the VPC."
  type        = string
}

variable "availability_zone" {
  description = "AZ hosting both subnets."
  type        = string
}

variable "public_subnet_cidr" {
  description = "CIDR of the public subnet."
  type        = string
}

variable "private_subnet_cidr" {
  description = "CIDR of the private subnet."
  type        = string
}
