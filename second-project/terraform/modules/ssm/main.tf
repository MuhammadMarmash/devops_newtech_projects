# Terraform owns the existence of these parameters; the Phase 2/3 Python orchestrator
# owns the contents of two of them. Creating them here means `terraform destroy` removes
# them, so no live bootstrap token outlives its cluster, and the Terraform-to-Python
# contract is visible in the IaC rather than implied.

resource "aws_ssm_parameter" "api_endpoint" {
  name        = "${var.ssm_path_prefix}/api-endpoint"
  description = "Control plane private IP"
  type        = "String"
  value       = var.api_endpoint
}

# ignore_changes is load-bearing. Without it, the next apply would notice the real CA
# certificate differs from "PLACEHOLDER" and overwrite the cluster's CA — breaking every
# node — during an apply run for an entirely unrelated reason.
resource "aws_ssm_parameter" "ca_crt" {
  name        = "${var.ssm_path_prefix}/ca.crt"
  description = "Cluster CA certificate; written by the Phase 2 orchestrator"
  type        = "String"
  value       = "PLACEHOLDER"

  lifecycle {
    ignore_changes = [value]
  }
}

# SecureString because this is, briefly, a credential that authenticates an unknown
# machine to the apiserver.
resource "aws_ssm_parameter" "bootstrap_token" {
  name        = "${var.ssm_path_prefix}/bootstrap-token"
  description = "Kubelet TLS bootstrap token; written by the Phase 3 orchestrator"
  type        = "SecureString"
  value       = "PLACEHOLDER"

  lifecycle {
    ignore_changes = [value]
  }
}
