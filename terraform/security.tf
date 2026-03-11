# ─── security.tf ──────────────────────────────────────────────
# Security groups

resource "aws_security_group" "portfolio" {
  #checkov:skip=CKV_AWS_260:Port 80 required for Let's Encrypt ACME webroot challenge and HTTP→HTTPS redirect
  #checkov:skip=CKV_AWS_382:Unrestricted egress required — web server pulls images from ECR, fetches OS updates, calls external APIs
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
    description = "SSH (restricted to your IP)"
  }

  # Node Exporter — Prometheus scrape (Grafana server only, never public)
  ingress {
    from_port   = 9100
    to_port     = 9100
    protocol    = "tcp"
    cidr_blocks = ["${data.aws_ssm_parameter.grafana_eip.value}/32"]
    description = "Node Exporter metrics (Grafana server only)"
  }

  # cAdvisor — disabled on t3.nano (OOM risk). Uncomment if upgraded to t3.micro or larger.
  # ingress {
  #   from_port   = 8080
  #   to_port     = 8080
  #   protocol    = "tcp"
  #   cidr_blocks = ["${data.aws_ssm_parameter.grafana_eip.value}/32"]
  #   description = "cAdvisor container metrics (Grafana server only)"
  # }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound"
  }

  tags = { Name = "portfolio-sg" }
}
