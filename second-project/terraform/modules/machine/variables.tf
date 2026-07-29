variable "name" {
  description = "Machine name; becomes the Name tag and the inventory key."
  type        = string
}

variable "ami_id" {
  description = "AMI ID. Resolved once in the root so every machine gets the same image."
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type."
  type        = string
}

variable "volume_size_gb" {
  description = "Root volume size in GB."
  type        = number
}

variable "subnet_id" {
  description = "Subnet to launch into."
  type        = string
}

variable "security_group_ids" {
  description = "Security groups to attach."
  type        = list(string)
}

variable "key_name" {
  description = "EC2 key pair name."
  type        = string
}

variable "iam_instance_profile" {
  description = "Instance profile name."
  type        = string
}

variable "associate_public_ip" {
  description = "Whether to attach a public IP. True for the jumpbox only."
  type        = bool
  default     = false
}

variable "source_dest_check" {
  description = "Set false on workers so EC2 stops dropping pod-sourced packets."
  type        = bool
  default     = true
}

variable "user_data" {
  description = "Cloud-init payload. Unused in Phase 1; Phase 4 supplies the worker bootstrap."
  type        = string
  default     = null
}
