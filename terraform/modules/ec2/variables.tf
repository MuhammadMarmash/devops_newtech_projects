variable "security_group_id" {
  description = "The ID of the security group to associate with the EC2 instance"
  type        = string
}

variable "instance_type" {
  description = "The type of instance to create"
  type        = string
  default     = "t3.micro"
}

variable "ami" {
  description = "The AMI ID to use for the instance"
  type        = string
  default     = "ami-0189c3f216088b7db"
}

variable "size" {
  description = "The size of the root volume in GB"
  type        = number
  default     = 8
}

variable "volume_type" {
  description = "The type of the root volume"
  type        = string
  default     = "gp2"
}

variable "project_name" {
  description = "The name of the project"
  type        = string
}

variable "environment" {
  description = "The environment (e.g., dev, staging, prod)"
  type        = string
}

variable "subnet_id" {
    description = "The ID of the subnet to launch the instance in"
    type        = string
  }

# ---- Application provisioning (user_data template) ------------------------

variable "repo_url" {
  description = "HTTPS URL of the Git repository to clone and deploy"
  type        = string
  default     = "https://github.com/MuhammadMarmash/devops-mini-project1.git"
}

variable "repo_branch" {
  description = "Git branch to deploy"
  type        = string
  default     = "main"
}

variable "app_user" {
  description = "System user that owns and runs the application"
  type        = string
  default     = "appuser"
}

variable "app_home" {
  description = "Directory the repository is cloned into"
  type        = string
  default     = "/opt/todo-api"
}

variable "app_subdir" {
  description = "Path within the repo to the app dir (containing main.py / requirements.txt)"
  type        = string
  default     = "app"
}

variable "wsgi_target" {
  description = "Gunicorn WSGI target, in <module>:<app variable> form"
  type        = string
  default     = "main:app"
}

variable "app_port" {
  description = "Port the application listens on"
  type        = number
  default     = 5000
}

variable "gunicorn_workers" {
  description = "Number of gunicorn worker processes"
  type        = number
  default     = 3
}

