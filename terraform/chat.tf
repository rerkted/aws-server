# ─── chat.tf ──────────────────────────────────────────────────
# DNS record for ai.rerktserver.com subdomain

resource "aws_route53_record" "ai" {
  zone_id = data.aws_route53_zone.domain.zone_id
  name    = "ai.${var.domain_name}"
  type    = "A"
  ttl     = 300
  records = [aws_eip.portfolio.public_ip]
}
