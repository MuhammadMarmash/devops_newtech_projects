variable "vpc_id" {
  description = "The ID of the VPC where the security group will be created"
  type        = string
}

variable "allowed_cidr_blocks" {
  description = "List of CIDR blocks allowed for HTTP and HTTPS access"
  type        = list(string)
  default     = ["0.0.0.0/0"]

}
variable "allowed_ports" {
  description = "List of ports allowed for HTTP and HTTPS access"
  type        = list(number)
  default     = [80, 443, 5000]
}

variable "project_name" {
  description = "The name of the project"
  type        = string
}

variable "environment" {
  description = "The environment (e.g., dev, staging, prod)"
  type        = string
}
