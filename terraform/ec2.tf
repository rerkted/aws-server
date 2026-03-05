# ─── ec2.tf ───────────────────────────────────────────────────
# EC2 instance and Elastic IP

resource "aws_instance" "portfolio" {
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.portfolio.id]
  iam_instance_profile   = aws_iam_instance_profile.portfolio.name
  key_name               = var.key_pair_name

  root_block_device {
    volume_size           = 30
    volume_type           = "gp3"
    delete_on_termination = true
    encrypted             = true  # Encrypt EBS at rest
  }

  # Bootstrap script — installs Docker, pulls image, issues SSL cert
  user_data = base64encode(templatefile("${path.module}/userdata.sh", {
    ecr_registry = aws_ecr_repository.portfolio.repository_url
    aws_region   = var.aws_region
    domain_name  = var.domain_name
    admin_email  = var.admin_email
  }))

  lifecycle {
    create_before_destroy = true
  }

  tags = { Name = "portfolio-ec2" }
}

# Static IP — persists across stop/start so DNS never needs updating
resource "aws_eip" "portfolio" {
  instance = aws_instance.portfolio.id
  domain   = "vpc"

  tags = { Name = "portfolio-eip" }
}
