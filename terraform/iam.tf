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

resource "aws_iam_instance_profile" "portfolio" {
  name = "portfolio-instance-profile"
  role = aws_iam_role.ec2_portfolio.name
}
