# ---------------------------------------------------------------------------
# GitHub Actions OIDC trust
#
# Lets the deploy workflow authenticate to AWS with NO long-lived access keys.
# GitHub mints a short-lived OIDC token per run; AWS trusts it ONLY for this
# repo on the main branch (the `sub` condition below), then hands back
# temporary credentials scoped to the permissions in the attached policy.
# ---------------------------------------------------------------------------

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

resource "aws_iam_role" "github_deploy" {
  name = "github-deploy-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        # Only workflows on main of THIS repo may assume the role.
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "repo:MuhammadMarmash/devops-mini-project1:ref:refs/heads/main"
        }
      }
    }]
  })
}

# Least-privilege: find the running instance + push the deploy command via SSM.
resource "aws_iam_role_policy" "github_deploy_ssm" {
  name = "allow-ssm-deploy"
  role = aws_iam_role.github_deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "FindInstance"
        Effect   = "Allow"
        Action   = ["ec2:DescribeInstances"]
        Resource = "*"
      },
      {
        Sid      = "RunDeployCommand"
        Effect   = "Allow"
        Action   = ["ssm:SendCommand", "ssm:GetCommandInvocation"]
        Resource = "*"
      }
    ]
  })
}

output "github_deploy_role_arn" {
  description = "ARN to put in the deploy workflow's role-to-assume"
  value       = aws_iam_role.github_deploy.arn
}
