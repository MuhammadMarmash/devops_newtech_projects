resource "aws_security_group" "main" {
  name        = "main"
  description = "Main security group"
  vpc_id      = var.vpc_id
  tags = {
    Project     = var.project_name
    Environment = var.environment
    name        = "${var.project_name}-${var.environment}-sg"
  }
}

resource "aws_security_group_rule" "http_https" {
  count             = length(var.allowed_ports)
  type              = "ingress"
  from_port         = var.allowed_ports[count.index]
  to_port           = var.allowed_ports[count.index]
  protocol          = "tcp"
  cidr_blocks       = var.allowed_cidr_blocks
  security_group_id = aws_security_group.main.id
}

resource "aws_security_group_rule" "outbound" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.main.id
}
