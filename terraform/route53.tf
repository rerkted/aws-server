# ─── route53.tf ───────────────────────────────────────────────
# DNS records for rerktserver.com

data "aws_route53_zone" "domain" {
  name         = var.domain_name
  private_zone = false
}

# rerktserver.com → CloudFront (Phase 1 of the CloudFront rollout —
# see terraform/cloudfront.tf and the migration plan). ai./agent.
# stay on direct EIP records until their own later phases.
resource "aws_route53_record" "root" {
  zone_id = data.aws_route53_zone.domain.zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.portfolio.domain_name
    zone_id                = aws_cloudfront_distribution.portfolio.hosted_zone_id
    evaluate_target_health = false
  }
}

# www.rerktserver.com → CloudFront
resource "aws_route53_record" "www" {
  zone_id = data.aws_route53_zone.domain.zone_id
  name    = "www.${var.domain_name}"
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.portfolio.domain_name
    zone_id                = aws_cloudfront_distribution.portfolio.hosted_zone_id
    evaluate_target_health = false
  }
}
