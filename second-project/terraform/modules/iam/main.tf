data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

locals {
  # A path wildcard, not enumerated ARNs. Phase 3's orchestrator mints the bootstrap
  # token into SSM at runtime, so Terraform can never know that parameter's ARN. A policy
  # listing only Terraform-known ARNs would break Phase 4's worker bootstrap.
  ssm_parameter_arn = join("", [
    "arn:", data.aws_partition.current.partition,
    ":ssm:", data.aws_region.current.name,
    ":", data.aws_caller_identity.current.account_id,
    ":parameter", var.ssm_path_prefix, "/*",
  ])

  kms_via_ssm = "ssm.${data.aws_region.current.name}.amazonaws.com"
}

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

# ---------- jumpbox: the only writer ----------

data "aws_iam_policy_document" "jumpbox" {
  statement {
    sid    = "ReadWriteClusterParameters"
    effect = "Allow"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:GetParametersByPath",
      "ssm:PutParameter",
    ]
    resources = [local.ssm_parameter_arn]
  }

  # SecureString reads and writes fail without this, and the denial is raised by KMS
  # rather than SSM — so the error points at the wrong service. Scoped by ViaService so
  # the key can only be used through SSM.
  statement {
    sid       = "UseSsmKeyViaSsmOnly"
    effect    = "Allow"
    actions   = ["kms:Encrypt", "kms:Decrypt"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = [local.kms_via_ssm]
    }
  }
}

resource "aws_iam_role" "jumpbox" {
  name               = "${var.name_prefix}-jumpbox"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy" "jumpbox" {
  name   = "${var.name_prefix}-jumpbox-ssm"
  role   = aws_iam_role.jumpbox.id
  policy = data.aws_iam_policy_document.jumpbox.json
}

resource "aws_iam_instance_profile" "jumpbox" {
  name = "${var.name_prefix}-jumpbox"
  role = aws_iam_role.jumpbox.name
}

# ---------- nodes: read only ----------

# A compromised worker must not be able to rewrite /kthw/ca.crt and hand every future
# node a CA we do not control.
data "aws_iam_policy_document" "node" {
  statement {
    sid    = "ReadClusterParameters"
    effect = "Allow"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:GetParametersByPath",
    ]
    resources = [local.ssm_parameter_arn]
  }

  statement {
    sid       = "DecryptSsmSecureStringsOnly"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = [local.kms_via_ssm]
    }
  }
}

resource "aws_iam_role" "node" {
  name               = "${var.name_prefix}-node"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy" "node" {
  name   = "${var.name_prefix}-node-ssm"
  role   = aws_iam_role.node.id
  policy = data.aws_iam_policy_document.node.json
}

resource "aws_iam_instance_profile" "node" {
  name = "${var.name_prefix}-node"
  role = aws_iam_role.node.name
}
