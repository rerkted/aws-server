# ─── main.tf ──────────────────────────────────────────────────
# Portfolio Infrastructure — Cost-optimized, repeatable

terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Remote state (uncomment after creating S3 bucket manually once)
  # backend "s3" {
  #   bucket = "your-name-tf-state"
  #   key    = "portfolio/terraform.tfstate"
  #   region = "us-east-1"
  # }
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      Project     = "portfolio"
      ManagedBy   = "terraform"
      Environment = var.environment
    }
  }
}

# ─── DATA ─────────────────────────────────────────────────────

data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

data "aws_availability_zones" "available" {}

# ─── NETWORKING ───────────────────────────────────────────────

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# ─── SECURITY GROUP ───────────────────────────────────────────

resource "aws_security_group" "portfolio" {
  name        = "portfolio-sg"
  description = "Portfolio website security group"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTP"
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTPS"
  }

  # Restrict SSH to your IP only — set in terraform.tfvars
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.your_ip_cidr]
    description = "SSH (restricted)"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ─── ECR REPOSITORY (Golden image store) ──────────────────────

resource "aws_ecr_repository" "portfolio" {
  name                 = "portfolio"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true  # Free vulnerability scanning
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_ecr_lifecycle_policy" "portfolio" {
  repository = aws_ecr_repository.portfolio.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep only last 5 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 5
      }
      action = { type = "expire" }
    }]
  })
}

# ─── IAM ROLE FOR EC2 ─────────────────────────────────────────

resource "aws_iam_role" "ec2_portfolio" {
  name = "portfolio-ec2-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecr_read" {
  role       = aws_iam_role.ec2_portfolio.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ec2_portfolio.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "portfolio" {
  name = "portfolio-instance-profile"
  role = aws_iam_role.ec2_portfolio.name
}

# ─── EC2 INSTANCE ─────────────────────────────────────────────

resource "aws_instance" "portfolio" {
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = var.instance_type  # t3.nano = ~$3.50/mo
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.portfolio.id]
  iam_instance_profile   = aws_iam_instance_profile.portfolio.name
  key_name               = var.key_pair_name

  root_block_device {
    volume_size           = 30
    volume_type           = "gp3"
    delete_on_termination = true
    encrypted             = true
  }

  user_data = base64encode(templatefile("${path.module}/userdata.sh", {
    ecr_registry = aws_ecr_repository.portfolio.repository_url
    aws_region   = var.aws_region
    domain_name  = var.domain_name
    admin_email  = var.admin_email
  }))

  lifecycle {
    create_before_destroy = true
  }
}

# ─── ELASTIC IP ───────────────────────────────────────────────

resource "aws_eip" "portfolio" {
  instance = aws_instance.portfolio.id
  domain   = "vpc"
}

# ─── OUTPUTS ──────────────────────────────────────────────────

output "public_ip" {
  value       = aws_eip.portfolio.public_ip
  description = "Portfolio public IP — point your DNS here"
}

output "ecr_repository_url" {
  value       = aws_ecr_repository.portfolio.repository_url
  description = "ECR URL for pushing Docker images"
}

output "instance_id" {
  value = aws_instance.portfolio.id
}

output "site_url" {
  value       = "https://${var.domain_name}"
  description = "Your live site URL"
}

# ─── ROUTE53 DNS ──────────────────────────────────────────────

data "aws_route53_zone" "domain" {
  name         = var.domain_name
  private_zone = false
}

# A record: rerktserver.com → Elastic IP
resource "aws_route53_record" "root" {
  zone_id = data.aws_route53_zone.domain.zone_id
  name    = var.domain_name
  type    = "A"
  ttl     = 300
  records = [aws_eip.portfolio.public_ip]
}

# A record: www.rerktserver.com → Elastic IP
resource "aws_route53_record" "www" {
  zone_id = data.aws_route53_zone.domain.zone_id
  name    = "www.${var.domain_name}"
  type    = "A"
  ttl     = 300
  records = [aws_eip.portfolio.public_ip]
}
