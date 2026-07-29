variable "ssm_path_prefix" {
  description = "Path prefix for all cluster parameters."
  type        = string
}

variable "api_endpoint" {
  description = "Private IP of the control plane, read by worker user_data in Phase 4."
  type        = string
}
