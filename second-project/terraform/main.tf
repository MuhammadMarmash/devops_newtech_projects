# Resolved once, in the root, so all machines land on one image. "Most recent Debian 13"
# is a moving target — four independent lookups could disagree mid-apply.
data "aws_ami" "debian" {
  most_recent = true
  owners      = ["136693071363"] # Debian

  filter {
    name   = "name"
    values = ["debian-13-amd64-*"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

# One instantiation, zero reuse: a module boundary here would be indirection with no
# benefit. Known tradeoff — the private key lands in plaintext in local state, acceptable
# only because state is local and gitignored.
resource "tls_private_key" "ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "ssh" {
  key_name   = "${var.name_prefix}-key"
  public_key = tls_private_key.ssh.public_key_openssh
}

resource "local_sensitive_file" "ssh_private_key" {
  filename        = "${path.module}/${var.name_prefix}.pem"
  content         = tls_private_key.ssh.private_key_pem
  file_permission = "0600"
}

module "network" {
  source = "./modules/network"

  name_prefix         = var.name_prefix
  vpc_cidr            = var.vpc_cidr
  availability_zone   = var.availability_zone
  public_subnet_cidr  = var.public_subnet_cidr
  private_subnet_cidr = var.private_subnet_cidr
}

module "security" {
  source = "./modules/security"

  name_prefix       = var.name_prefix
  vpc_id            = module.network.vpc_id
  ssh_allowed_cidrs = var.ssh_allowed_cidrs
  pod_cidr          = var.pod_cidr
}

module "iam" {
  source = "./modules/iam"

  name_prefix     = var.name_prefix
  ssm_path_prefix = var.ssm_path_prefix
}

module "jumpbox" {
  source = "./modules/machine"

  name                 = "jumpbox"
  ami_id               = data.aws_ami.debian.id
  instance_type        = var.jumpbox_instance_type
  volume_size_gb       = var.jumpbox_volume_size_gb
  subnet_id            = module.network.public_subnet_id
  security_group_ids   = [module.security.jumpbox_sg_id, module.security.cluster_sg_id]
  key_name             = aws_key_pair.ssh.key_name
  iam_instance_profile = module.iam.jumpbox_instance_profile_name
  associate_public_ip  = true
}

# The control plane runs no kubelet and schedules no pods, so it never routes pod
# traffic and keeps source_dest_check at its default true.
module "server" {
  source = "./modules/machine"

  name                 = "server"
  ami_id               = data.aws_ami.debian.id
  instance_type        = var.server_instance_type
  volume_size_gb       = var.node_volume_size_gb
  subnet_id            = module.network.private_subnet_id
  security_group_ids   = [module.security.cluster_sg_id]
  key_name             = aws_key_pair.ssh.key_name
  iam_instance_profile = module.iam.node_instance_profile_name

  depends_on = [module.network]
}

# Keyed by name rather than count: with count, removing node-0 renumbers and rebuilds
# every later worker. Phase 4's success criterion is "add one node and it joins".
module "workers" {
  source   = "./modules/machine"
  for_each = { for i in range(var.worker_count) : "node-${i}" => i }

  name                 = each.key
  ami_id               = data.aws_ami.debian.id
  instance_type        = var.worker_instance_type
  volume_size_gb       = var.node_volume_size_gb
  subnet_id            = module.network.private_subnet_id
  security_group_ids   = [module.security.cluster_sg_id]
  key_name             = aws_key_pair.ssh.key_name
  iam_instance_profile = module.iam.node_instance_profile_name

  # Pod IPs are not the instance's own address, so EC2 drops them silently unless this
  # is off.
  source_dest_check = false

  # Without this a worker's user_data can start before the NAT route exists and fail
  # every download, with no error that points at the network.
  depends_on = [module.network]
}
