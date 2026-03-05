# ─── route53.tf ───────────────────────────────────────────────
# DNS records for rerktserver.com

data "aws_route53_zone" "domain" {
  name         = var.domain_name
  private_zone = false
}

# rerktserver.com → Elastic IP
resource "aws_route53_record" "root" {
  zone_id = data.aws_route53_zone.domain.zone_id
  name    = var.domain_name
  type    = "A"
  ttl     = 300
  records = [aws_eip.portfolio.public_ip]
}

# www.rerktserver.com → Elastic IP
resource "aws_route53_record" "www" {
  zone_id = data.aws_route53_zone.domain.zone_id
  name    = "www.${var.domain_name}"
  type    = "A"
  ttl     = 300
  records = [aws_eip.portfolio.public_ip]
}
