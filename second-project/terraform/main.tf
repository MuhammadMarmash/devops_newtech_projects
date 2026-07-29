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
