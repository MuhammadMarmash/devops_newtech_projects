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
  route_table_id  = module.network.private_route_table_id
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

module "ssm" {
  source = "./modules/ssm"

  ssm_path_prefix = var.ssm_path_prefix
  api_endpoint    = module.server.private_ip
}

locals {
  ca_conf_rendered = templatefile("${path.module}/scripts/ca.conf.template", {
    service_cluster_ip = cidrhost(var.service_cidr, 1)
    server_private_ip  = module.server.private_ip
    worker_ips         = { for name, w in module.workers : name => w.private_ip }
  })

  node_ips_csv = join(",", [for name, w in module.workers : "${name}=${w.private_ip}"])

  worker_node_data_csv = join(",", [for name, w in module.workers : "${name}=${w.private_ip}=${w.primary_network_interface_id}"])

  kube_apiserver_service_rendered = templatefile("${path.module}/scripts/kube-apiserver.service.template", {
    service_account_issuer = "https://${module.server.private_ip}:6443"
    service_cidr           = var.service_cidr
  })

  kube_controller_manager_service_rendered = templatefile("${path.module}/scripts/kube-controller-manager.service.template", {
    pod_cidr     = var.pod_cidr
    service_cidr = var.service_cidr
  })

  kube_proxy_service_rendered = templatefile("${path.module}/scripts/kube-proxy-config.yaml.template", {
    pod_cidr = var.pod_cidr
  })
}

resource "null_resource" "cert_bootstrap" {
  triggers = {
    server_ip  = module.server.private_ip
    worker_ips = local.node_ips_csv
  }

  depends_on = [module.network, module.security]

  connection {
    type        = "ssh"
    host        = module.jumpbox.public_ip
    user        = "admin"
    private_key = tls_private_key.ssh.private_key_pem
    timeout     = "5m"
  }

  provisioner "file" {
    content     = local.ca_conf_rendered
    destination = "/home/admin/ca.conf"
  }

  provisioner "file" {
    source      = "${path.module}/scripts/generate-certs.sh"
    destination = "/home/admin/generate-certs.sh"
  }

  provisioner "file" {
    content     = tls_private_key.ssh.private_key_pem
    destination = "/home/admin/kthw.pem"
  }

  provisioner "remote-exec" {
    inline = [
      "set -e",
      "cloud-init status --wait",
      "chmod 600 /home/admin/kthw.pem",
      "chmod +x /home/admin/generate-certs.sh",
      "sudo apt-get update -qq",
      "sudo apt-get install -y -qq awscli",
      "REGION=${var.region} SERVER_IP=${module.server.private_ip} SSM_PARAM_NAME=${module.ssm.parameter_names.ca_crt} NODE_IPS=${local.node_ips_csv} /home/admin/generate-certs.sh",
    ]
  }
}

resource "null_resource" "control_plane_bootstrap" {
  triggers = {
    server_ip = module.server.private_ip
  }

  depends_on = [null_resource.cert_bootstrap]

  connection {
    type        = "ssh"
    host        = module.jumpbox.public_ip
    user        = "admin"
    private_key = tls_private_key.ssh.private_key_pem
    timeout     = "5m"
  }

  provisioner "file" {
    source      = "${path.module}/scripts/downloads-amd64.txt"
    destination = "/home/admin/downloads-amd64.txt"
  }

  provisioner "file" {
    source      = "${path.module}/scripts/kube-scheduler.yaml"
    destination = "/home/admin/kube-scheduler.yaml"
  }

  provisioner "file" {
    source      = "${path.module}/scripts/kube-apiserver-to-kubelet.yaml"
    destination = "/home/admin/kube-apiserver-to-kubelet.yaml"
  }

  provisioner "file" {
    source      = "${path.module}/scripts/etcd.service"
    destination = "/home/admin/etcd.service"
  }

  provisioner "file" {
    source      = "${path.module}/scripts/kube-scheduler.service"
    destination = "/home/admin/kube-scheduler.service"
  }

  provisioner "file" {
    content     = local.kube_apiserver_service_rendered
    destination = "/home/admin/kube-apiserver.service"
  }

  provisioner "file" {
    content     = local.kube_controller_manager_service_rendered
    destination = "/home/admin/kube-controller-manager.service"
  }

  provisioner "file" {
    source      = "${path.module}/scripts/encryption-config.yaml.template"
    destination = "/home/admin/encryption-config.yaml.template"
  }

  provisioner "file" {
    source      = "${path.module}/scripts/bootstrap-control-plane.sh"
    destination = "/home/admin/bootstrap-control-plane.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "set -e",
      "sudo apt-get install -y -qq gettext-base",
      "chmod +x /home/admin/bootstrap-control-plane.sh",
      "REGION=${var.region} SERVER_IP=${module.server.private_ip} ENCRYPTION_KEY_SSM_PARAM=${module.ssm.parameter_names.encryption_key} /home/admin/bootstrap-control-plane.sh",
    ]
  }
}

resource "null_resource" "worker_binaries_prepared" {
  triggers = {
    server_ip = module.server.private_ip
  }

  depends_on = [null_resource.control_plane_bootstrap]

  connection {
    type        = "ssh"
    host        = module.jumpbox.public_ip
    user        = "admin"
    private_key = tls_private_key.ssh.private_key_pem
    timeout     = "5m"
  }

  provisioner "file" {
    source      = "${path.module}/scripts/prepare-worker-binaries.sh"
    destination = "/home/admin/prepare-worker-binaries.sh"
  }

  provisioner "file" {
    source      = "${path.module}/scripts/99-loopback.conf"
    destination = "/home/admin/99-loopback.conf"
  }

  provisioner "file" {
    source      = "${path.module}/scripts/containerd-config.toml"
    destination = "/home/admin/containerd-config.toml"
  }

  provisioner "file" {
    source      = "${path.module}/scripts/kubelet-config.yaml"
    destination = "/home/admin/kubelet-config.yaml"
  }

  provisioner "file" {
    content     = local.kube_proxy_service_rendered
    destination = "/home/admin/kube-proxy-config.yaml"
  }

  provisioner "file" {
    source      = "${path.module}/scripts/containerd.service"
    destination = "/home/admin/containerd.service"
  }

  provisioner "file" {
    source      = "${path.module}/scripts/kubelet.service"
    destination = "/home/admin/kubelet.service"
  }

  provisioner "file" {
    source      = "${path.module}/scripts/kube-proxy.service"
    destination = "/home/admin/kube-proxy.service"
  }

  provisioner "file" {
    source      = "${path.module}/scripts/bootstrap-worker.sh"
    destination = "/home/admin/bootstrap-worker.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "set -e",
      "chmod +x /home/admin/prepare-worker-binaries.sh",
      "chmod +x /home/admin/bootstrap-worker.sh",
      "/home/admin/prepare-worker-binaries.sh",
    ]
  }
}

resource "null_resource" "worker_bootstrap" {
  for_each = module.workers

  triggers = {
    worker_ip = each.value.private_ip
  }

  depends_on = [null_resource.worker_binaries_prepared]

  connection {
    type        = "ssh"
    host        = module.jumpbox.public_ip
    user        = "admin"
    private_key = tls_private_key.ssh.private_key_pem
    timeout     = "5m"
  }

  provisioner "remote-exec" {
    inline = [
      "set -e",
      "WORKER_IP=${each.value.private_ip} /home/admin/bootstrap-worker.sh",
    ]
  }
}

resource "null_resource" "pod_networking" {
  triggers = {
    worker_node_data = local.worker_node_data_csv
  }

  depends_on = [null_resource.worker_bootstrap]

  connection {
    type        = "ssh"
    host        = module.jumpbox.public_ip
    user        = "admin"
    private_key = tls_private_key.ssh.private_key_pem
    timeout     = "5m"
  }

  provisioner "file" {
    source      = "${path.module}/scripts/10-bridge.conf.template"
    destination = "/home/admin/10-bridge.conf.template"
  }

  provisioner "file" {
    source      = "${path.module}/scripts/configure-pod-networking.sh"
    destination = "/home/admin/configure-pod-networking.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "set -e",
      "chmod +x /home/admin/configure-pod-networking.sh",
      "REGION=${var.region} ROUTE_TABLE_ID=${module.network.private_route_table_id} NODE_DATA=${local.worker_node_data_csv} /home/admin/configure-pod-networking.sh",
    ]
  }
}
