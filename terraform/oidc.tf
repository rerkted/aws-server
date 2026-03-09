# ─── oidc.tf ──────────────────────────────────────────────────
# OIDC federation — allows GitHub Actions to assume an AWS IAM
# role directly, eliminating long-lived access keys entirely.
#
# How it works:
#   1. AWS trusts GitHub's OIDC identity provider
#   2. GitHub Actions requests a short-lived token (~1 hour)
#   3. Token is scoped to this repo + main branch only
#   4. No AWS_ACCESS_KEY_ID or AWS_SECRET_ACCESS_KEY needed

# ─── OIDC IDENTITY PROVIDER ───────────────────────────────────
## Tells AWS to trust tokens issued by GitHub Actions

resource "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"

  # GitHub's OIDC audience
  client_id_list = ["sts.amazonaws.com"]

  # GitHub's OIDC thumbprint — stable, does not change
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]

  tags = { Name = "github-actions-oidc" }
}

# ─── IAM ROLE ─────────────────────────────────────────────────
# The role GitHub Actions will assume during pipeline runs

resource "aws_iam_role" "github_actions_oidc" {
  name        = "github-actions-oidc-role"
  description = "Assumed by GitHub Actions via OIDC - no static keys"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "GitHubOIDC"
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.github.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            # Only tokens for YOUR repo are accepted
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }
          StringLike = {
            # Only main branch of trusted repos can assume this role
            "token.actions.githubusercontent.com:sub" = [
              "repo:${var.github_org}/${var.github_repo}:ref:refs/heads/main",
              "repo:${var.github_org}/${var.github_repo}:environment:production",
              "repo:${var.github_org}/aws-grafana:ref:refs/heads/main"
            ]
          }
        }
      }
    ]
  })

  tags = { Name = "github-actions-oidc-role" }
}

# ─── IAM POLICY ───────────────────────────────────────────────
# Least privilege — only what the pipeline actually needs

resource "aws_iam_role_policy" "github_actions_deploy" {
  #checkov:skip=CKV_AWS_355:ssm:SendCommand and ec2:DescribeInstances require wildcard — no resource-level restriction supported
  #checkov:skip=CKV_AWS_290:ssm:GetParameter scoped to rerktserver/* path; SSM action wildcards are service-limited
  #checkov:skip=CKV_AWS_288:ecr:GetAuthorizationToken requires wildcard resource — no resource-level restriction supported by ECR auth
  name = "github-actions-deploy-policy"
  role = aws_iam_role.github_actions_oidc.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ECRAuth"
        Effect = "Allow"
        Action = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Sid    = "ECRPush"
        Effect = "Allow"
        Action = [
          "ecr:BatchGetImage",
          "ecr:BatchCheckLayerAvailability",
          "ecr:CompleteLayerUpload",
          "ecr:GetDownloadUrlForLayer",
          "ecr:InitiateLayerUpload",
          "ecr:PutImage",
          "ecr:UploadLayerPart",
          "ecr:DescribeRepositories",
          "ecr:ListImages"
        ]
        Resource = [
          aws_ecr_repository.portfolio.arn,
          aws_ecr_repository.rerkt_ai.arn,
          aws_ecr_repository.bedrock_ai.arn
        ]
      },
      {
        Sid    = "SSMDeploy"
        Effect = "Allow"
        Action = [
          "ssm:SendCommand",
          "ssm:GetCommandInvocation",
          "ssm:ListCommandInvocations",
          "ssm:DescribeInstanceInformation",
          "ssm:GetParameter"
        ]
        Resource = "*"
      },
      {
        Sid      = "EC2Describe"
        Effect   = "Allow"
        Action   = ["ec2:DescribeInstances"]
        Resource = "*"
      }
    ]
  })
}

# ─── OUTPUT ───────────────────────────────────────────────────
# Copy this ARN into GitHub Secrets as AWS_OIDC_ROLE_ARN

output "oidc_role_arn" {
  value       = aws_iam_role.github_actions_oidc.arn
  description = "Add this as GitHub Secret: AWS_OIDC_ROLE_ARN"
}
