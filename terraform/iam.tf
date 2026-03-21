# ─── iam.tf ───────────────────────────────────────────────────
# IAM role and policies for EC2 instance

resource "aws_iam_role" "ec2_portfolio" {
  name        = "portfolio-ec2-role"
  description = "IAM role for portfolio EC2 instance"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

# ECR read-only — pull images from registry
resource "aws_iam_role_policy_attachment" "ecr_read" {
  role       = aws_iam_role.ec2_portfolio.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# SSM — required for GitHub Actions SSM deploy (no SSH)
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ec2_portfolio.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Bedrock — allows EC2 to call AWS Bedrock without API keys
resource "aws_iam_role_policy" "bedrock_invoke" {
  #checkov:skip=CKV_AWS_355:aws-marketplace:Subscribe requires wildcard resource — no resource-level restriction supported by AWS
  name = "bedrock-invoke-policy"
  role = aws_iam_role.ec2_portfolio.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "BedrockInvoke"
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream"
        ]
        Resource = "arn:aws:bedrock:${var.aws_region}::foundation-model/anthropic.claude-3-haiku-20240307-v1:0"
      },
      {
        Sid    = "MarketplaceSubscribe"
        Effect = "Allow"
        Action = [
          "aws-marketplace:ViewSubscriptions",
          "aws-marketplace:Subscribe",
          "aws-marketplace:Unsubscribe"
        ]
        Resource = "*"
      }
    ]
  })
}

# SSM Parameter Store — read Grafana EIP at boot for Promtail config
resource "aws_iam_role_policy" "ssm_parameters" {
  #checkov:skip=CKV_AWS_290:kms:Decrypt requires wildcard resource — KMS key ARNs are dynamic and not known at Terraform time
  #checkov:skip=CKV_AWS_288:kms:Decrypt is scoped to the SSM namespace only; wildcard is on the KMS action not SSM
  #checkov:skip=CKV_AWS_355:kms:Decrypt requires wildcard resource — KMS key ARNs are dynamic
  name = "ssm-parameter-read"
  role = aws_iam_role.ec2_portfolio.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ssm:GetParameter"]
        Resource = "arn:aws:ssm:${var.aws_region}:*:parameter/${var.ssm_namespace}/*"
      },
      {
        Sid      = "KMSDecrypt"
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "portfolio" {
  name = "portfolio-instance-profile"
  role = aws_iam_role.ec2_portfolio.name
}

# Agent AI — EC2 read/modify permissions for infrastructure discovery and execution
resource "aws_iam_role_policy" "agent_permissions" {
  #checkov:skip=CKV_AWS_355:ec2:Describe* and route53:List* require wildcard — no resource-level restriction supported
  #checkov:skip=CKV_AWS_290:ec2:StartInstances/StopInstances/AuthorizeSecurityGroupIngress require wildcard resource — EC2 resource-level restrictions require tag conditions not applicable here
  name = "agent-infrastructure-policy"
  role = aws_iam_role.ec2_portfolio.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EC2Discover"
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances",
          "ec2:DescribeVpcs",
          "ec2:DescribeSubnets",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeAddresses",
          "ec2:DescribeRouteTables",
          "ec2:DescribeInternetGateways"
        ]
        Resource = "*"
      },
      {
        Sid    = "EC2Modify"
        Effect = "Allow"
        Action = [
          "ec2:StartInstances",
          "ec2:StopInstances",
          "ec2:AuthorizeSecurityGroupIngress",
          "ec2:RevokeSecurityGroupIngress"
        ]
        Resource = "*"
      },
      {
        Sid    = "ECRDiscover"
        Effect = "Allow"
        Action = [
          "ecr:DescribeRepositories",
          "ecr:ListImages"
        ]
        Resource = "*"
      },
      {
        Sid    = "SSMWrite"
        Effect = "Allow"
        Action = ["ssm:PutParameter"]
        Resource = "arn:aws:ssm:${var.aws_region}:*:parameter/${var.ssm_namespace}/*"
      }
    ]
  })
}
