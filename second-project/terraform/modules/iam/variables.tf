variable "name_prefix" {
  description = "Prefix for role and profile names."
  type        = string
}

variable "ssm_path_prefix" {
  description = "SSM path prefix the policies grant access beneath."
  type        = string
}
