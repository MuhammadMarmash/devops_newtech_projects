output "parameter_names" {
  description = "Parameter names for the orchestrator and worker user_data."
  value = {
    api_endpoint    = aws_ssm_parameter.api_endpoint.name
    ca_crt          = aws_ssm_parameter.ca_crt.name
    bootstrap_token = aws_ssm_parameter.bootstrap_token.name
    encryption_key  = aws_ssm_parameter.encryption_key.name
  }
}
