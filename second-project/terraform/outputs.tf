# Replaces machines.txt. Three deliberate departures from it:
#   1. private_ip is the primary field, and public_ip exists only on the jumpbox — so
#      using private IPs internally stops being a discipline to remember and becomes a
#      property of the data.
#   2. The old SUBNET column (hand-assigned pod CIDRs) is gone. Phase 5 delegates that to
#      controller-manager --allocate-node-cidrs; emitting it here would guarantee drift.
#   3. Roles are structural. inventory.py reads .workers rather than matching "node-*".
output "cluster" {
  description = "Machine inventory consumed by the Phase 2 Python orchestrator."
  value = {
    jumpbox = {
      name       = "jumpbox"
      private_ip = module.jumpbox.private_ip
      public_ip  = module.jumpbox.public_ip
      fqdn       = "jumpbox.${var.cluster_domain}"
    }
    server = {
      name       = "server"
      private_ip = module.server.private_ip
      fqdn       = "server.${var.cluster_domain}"
    }
    workers = {
      for name, m in module.workers : name => {
        name         = name
        private_ip   = m.private_ip
        fqdn         = "${name}.${var.cluster_domain}"
        interface_id = m.primary_network_interface_id
      }
    }
  }
}

output "ssh_private_key_path" {
  description = "Path to the generated private key. Gitignored."
  value       = local_sensitive_file.ssh_private_key.filename
}

output "jumpbox_ssh_command" {
  description = "Ready-to-run SSH command for the jumpbox."
  value       = "ssh -i ${local_sensitive_file.ssh_private_key.filename} admin@${module.jumpbox.public_ip}"
}

output "vpc_id" {
  description = "VPC ID."
  value       = module.network.vpc_id
}

output "private_route_table_id" {
  description = "Private route table. Phase 5 programs pod-CIDR routes into this."
  value       = module.network.private_route_table_id
}

output "ssm_parameter_names" {
  description = "SSM parameter names for the orchestrator and worker user_data."
  value       = module.ssm.parameter_names
}

output "service_cidr" {
  description = "Service network, recorded for Phase 2 apiserver certificate SANs."
  value       = var.service_cidr
}
