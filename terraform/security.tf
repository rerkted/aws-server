# ─── security.tf ──────────────────────────────────────────────
# Security groups

# Phase 4 of the CloudFront rollout: restricts port 443 to CloudFront's
# origin-facing IPs only, closing the direct-EIP-bypass gap Phases 1-3
# deliberately left open. AWS maintains this list's entries automatically
# as CloudFront's IP ranges change — no refresh mechanism needed on our
# end, unlike cloudfront-realip.conf (nginx has no native prefix-list
# support, so that one has to be regenerated from ip-ranges.json at
# deploy time instead).
data "aws_ec2_managed_prefix_list" "cloudfront_origin_facing" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

resource "aws_security_group" "portfolio" {
  #checkov:skip=CKV_AWS_260:Port 80 stays open to 0.0.0.0/0 intentionally — certbot's renewal cron validates the origin.DOMAIN_NAME SAN directly against the EIP (not through CloudFront, which can't be the origin's own origin), and Let's Encrypt's validator IPs aren't published/stable enough to allowlist. Restricting this would silently break cert renewal ~60-90 days later, taking down all three CloudFront distributions at once when the shared cert expires. See migration plan Phase 4. Port 80 itself serves no application content — only ACME challenges and a redirect to HTTPS.
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
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    prefix_list_ids = [data.aws_ec2_managed_prefix_list.cloudfront_origin_facing.id]
    description     = "HTTPS - CloudFront origin-facing only (see migration plan Phase 4)"
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
  # Only added when grafana stack is active (grafana_active=true)
  dynamic "ingress" {
    for_each = var.grafana_active ? [1] : []
    content {
      from_port   = 9100
      to_port     = 9100
      protocol    = "tcp"
      cidr_blocks = ["${data.aws_ssm_parameter.grafana_eip[0].value}/32"]
      description = "Node Exporter metrics (Grafana server only)"
    }
  }

  # cAdvisor — disabled on t3.nano (OOM risk). Uncomment if upgraded to t3.micro or larger.
  # dynamic "ingress" {
  #   for_each = var.grafana_active ? [1] : []
  #   content {
  #     from_port   = 8080
  #     to_port     = 8080
  #     protocol    = "tcp"
  #     cidr_blocks = ["${data.aws_ssm_parameter.grafana_eip[0].value}/32"]
  #     description = "cAdvisor container metrics (Grafana server only)"
  #   }
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
