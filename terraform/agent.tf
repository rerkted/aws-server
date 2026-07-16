# ─── agent.tf ─────────────────────────────────────────────────
# DNS record for agent.rerktserver.com subdomain
#
# agent.DOMAIN_NAME → CloudFront (Phase 3 of the CloudFront rollout — see
# cloudfront.tf's aws_cloudfront_distribution.agent and the migration plan).

resource "aws_route53_record" "agent" {
  zone_id = data.aws_route53_zone.domain.zone_id
  name    = "agent.${var.domain_name}"
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.agent.domain_name
    zone_id                = aws_cloudfront_distribution.agent.hosted_zone_id
    evaluate_target_health = false
  }
}
