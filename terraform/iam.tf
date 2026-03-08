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
        Resource = "arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-3-haiku-20240307-v1:0"
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
  name = "ssm-parameter-read"
  role = aws_iam_role.ec2_portfolio.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ssm:GetParameter"]
        Resource = "arn:aws:ssm:us-east-1:*:parameter/rerktserver/*"
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
