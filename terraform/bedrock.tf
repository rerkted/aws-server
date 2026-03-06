# ─── bedrock.tf ───────────────────────────────────────────────
# DNS record for bedrock.rerktserver.com subdomain

resource "aws_route53_record" "bedrock" {
  zone_id = data.aws_route53_zone.domain.zone_id
  name    = "bedrock.${var.domain_name}"
  type    = "A"
  ttl     = 300
  records = [aws_eip.portfolio.public_ip]
}
