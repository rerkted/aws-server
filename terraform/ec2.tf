# ─── ec2.tf ───────────────────────────────────────────────────
## EC2 instance and Elastic IP

resource "aws_instance" "portfolio" {
  #checkov:skip=CKV_AWS_135:T3 instances are automatically EBS-optimized; explicit flag unsupported
  #checkov:skip=CKV_AWS_126:Detailed monitoring disabled intentionally — cost vs. benefit for t3.nano
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.portfolio.id]
  iam_instance_profile   = aws_iam_instance_profile.portfolio.name
  key_name               = var.key_pair_name

  # CKV_AWS_79: Enforce IMDSv2 — prevents SSRF-based metadata credential theft
  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  root_block_device {
    volume_size           = 30
    volume_type           = "gp3"
    delete_on_termination = true
    encrypted             = true  # Encrypt EBS at rest
  }

  # Bootstrap script — installs Docker, pulls image, issues SSL cert
  user_data = base64encode(templatefile("${path.module}/userdata.sh", {
    ecr_registry  = aws_ecr_repository.portfolio.repository_url
    aws_region    = var.aws_region
    domain_name   = var.domain_name
    admin_email   = var.admin_email
    ssm_namespace = var.ssm_namespace
  }))

  lifecycle {
    create_before_destroy = true
    ignore_changes        = [ami, user_data]  # user_data only runs on first boot — changes don't affect running instance
  }

  tags = { Name = "portfolio-ec2" }
}

# Static IP — persists across stop/start so DNS never needs updating
resource "aws_eip" "portfolio" {
  instance = aws_instance.portfolio.id
  domain   = "vpc"

  tags = { Name = "portfolio-eip" }
}

# Store portfolio EIP and instance ID in SSM — deploy workflow reads these dynamically
resource "aws_ssm_parameter" "portfolio_eip" {
  #checkov:skip=CKV2_AWS_34:EIP is a public IP address — not sensitive data requiring SecureString
  name  = "/${var.ssm_namespace}/portfolio/eip"
  type  = "String"
  value = aws_eip.portfolio.public_ip

  tags = { Name = "portfolio-eip" }
}

resource "aws_ssm_parameter" "portfolio_instance_id" {
  #checkov:skip=CKV2_AWS_34:EC2 instance ID is not sensitive — used for SSM targeting
  name  = "/${var.ssm_namespace}/portfolio/instance-id"
  type  = "String"
  value = aws_instance.portfolio.id

  tags = { Name = "portfolio-instance-id" }
}
