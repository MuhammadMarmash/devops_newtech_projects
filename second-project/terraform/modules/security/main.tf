resource "aws_security_group" "jumpbox" {
  name        = "${var.name_prefix}-jumpbox"
  description = "Inbound SSH to the jumpbox from outside the VPC"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.name_prefix}-jumpbox"
  }
}

resource "aws_vpc_security_group_ingress_rule" "jumpbox_ssh" {
  for_each = toset(var.ssh_allowed_cidrs)

  security_group_id = aws_security_group.jumpbox.id
  description       = "SSH from ${each.value}"
  cidr_ipv4         = each.value
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
}

# Terraform strips AWS's default allow-all egress the moment a group is declared, so
# every group needs its egress stated explicitly.
resource "aws_vpc_security_group_egress_rule" "jumpbox_all" {
  security_group_id = aws_security_group.jumpbox.id
  description       = "All outbound"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_security_group" "cluster" {
  name        = "${var.name_prefix}-cluster"
  description = "All traffic between cluster members, plus pod network"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.name_prefix}-cluster"
  }
}

# AWS denies intra-VPC traffic by default. This self-reference is what lets etcd
# (2379/2380), the apiserver (6443), and kubelet (10250) talk, and what lets the jumpbox
# SSH into the private nodes.
resource "aws_vpc_security_group_ingress_rule" "cluster_self" {
  security_group_id            = aws_security_group.cluster.id
  description                  = "All traffic between members of this group"
  referenced_security_group_id = aws_security_group.cluster.id
  ip_protocol                  = "-1"
}

# A rule whose source is a security group is resolved by mapping the packet's source IP
# to an ENI carrying that group. A pod packet's source (10.200.x.x) belongs to no ENI,
# so the self-rule above cannot match it. Disabling source_dest_check gets the packet
# delivered; this rule is what stops the SG dropping it on ingress. Inert until Phase 5.
resource "aws_vpc_security_group_ingress_rule" "cluster_pods" {
  security_group_id = aws_security_group.cluster.id
  description       = "Pod network (Phase 5)"
  cidr_ipv4         = var.pod_cidr
  ip_protocol       = "-1"
}

resource "aws_vpc_security_group_egress_rule" "cluster_all" {
  security_group_id = aws_security_group.cluster.id
  description       = "All outbound, via NAT for private nodes"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}
