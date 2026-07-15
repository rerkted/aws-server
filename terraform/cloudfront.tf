# ─── cloudfront.tf ─────────────────────────────────────────────
# Phase 1 of the CloudFront rollout: fronts ONLY the root+www
# portfolio vhost. ai./agent. stay on direct EIP DNS until their own
# later phases add nginx's realip-module trust of CloudFront's edge
# IPs (needed so rate limiting, and agent.'s single-IP allowlist,
# keep working against the real client instead of CloudFront's edge)
# — see the migration plan for the full phase breakdown.
#
# Cost: CloudFront's 1TB/10M-request tier and ACM-for-CloudFront are
# both permanent AWS Always Free benefits, not a 12-month trial. This
# design intentionally avoids anything billed per-use — no S3 access
# logging, no dedicated/VIP viewer cert, no WAF.

## ─── ACM CERTIFICATE ──────────────────────────────────────────
# us-east-1 required for CloudFront — var.aws_region already
# defaults to us-east-1 for this whole stack, so no provider alias
# is needed. Wildcard + apex covers ai./agent./origin. too, so later
# phases never need a second cert or reissuance.

resource "aws_acm_certificate" "portfolio" {
  domain_name               = var.domain_name
  subject_alternative_names = ["*.${var.domain_name}"]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = { Name = "portfolio-acm-cert" }
}

resource "aws_route53_record" "acm_validation" {
  # Keyed on resource_record_name, not domain_name: an apex + wildcard
  # SAN pair (rerktserver.com + *.rerktserver.com) frequently validates
  # via the identical CNAME from ACM. Keying by domain_name would try to
  # create that same Route53 record twice and collide. The trailing
  # "..." groups duplicate keys into a list instead of erroring, which
  # is why each.value below is indexed [0] — all grouped entries share
  # the same underlying record, so any one of them is correct to use.
  for_each = {
    for dvo in aws_acm_certificate.portfolio.domain_validation_options : dvo.resource_record_name => {
      name  = dvo.resource_record_name
      type  = dvo.resource_record_type
      value = dvo.resource_record_value
    }...
  }

  zone_id         = data.aws_route53_zone.domain.zone_id
  name            = each.value[0].name
  type            = each.value[0].type
  ttl             = 300
  records         = [each.value[0].value]
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "portfolio" {
  certificate_arn         = aws_acm_certificate.portfolio.arn
  validation_record_fqdns = [for r in aws_route53_record.acm_validation : r.fqdn]
}

## ─── ORIGIN-FACING DNS RECORD ─────────────────────────────────
# CloudFront's Origin Domain Name can't be the apex/www (circular —
# those are about to alias to CloudFront) or ai./agent. (nginx would
# pick the wrong server{} block by SNI). This dedicated hostname is
# origin-facing infrastructure only, never given out publicly.
#
# Renewal-critical: this must be added as a SAN on the existing
# certbot lineage (one-time manual step, see migration plan and
# RUNBOOK.md) since certbot renews all SANs in one lineage together —
# do not decommission this record casually, the same way the earlier
# bedrock.DOMAIN_NAME orphaned-record incident broke renewal for
# every domain on the cert, not just the broken one.

resource "aws_route53_record" "origin" {
  zone_id = data.aws_route53_zone.domain.zone_id
  name    = "origin.${var.domain_name}"
  type    = "A"
  ttl     = 300
  records = [aws_eip.portfolio.public_ip]
}

## ─── CLOUDFRONT DISTRIBUTION ───────────────────────────────────

resource "aws_cloudfront_distribution" "portfolio" {
  #checkov:skip=CKV_AWS_86:Access logging to S3 disabled intentionally — cost avoidance, matches other cost-tradeoff decisions in this repo
  #checkov:skip=CKV_AWS_310:Origin failover not configured — single EC2 origin by design, no second origin to fail over to
  #checkov:skip=CKV_AWS_374:Geo restriction intentionally left open — personal portfolio site, no audience restriction needed
  #checkov:skip=CKV2_AWS_32:Response headers policy not attached — nginx already sets all security headers (HSTS, CSP, X-Frame-Options, etc.) at the origin and CloudFront passes them through unchanged
  #checkov:skip=CKV_AWS_305:Default root object not set — nginx's own try_files/index handling already covers this at the origin
  #checkov:skip=CKV_AWS_68:WAF intentionally out of scope for this rollout — real per-rule/per-request cost, conflicts with the no-additional-cost constraint on this phase. See migration plan.
  #checkov:skip=CKV2_AWS_47:Same reasoning as CKV_AWS_68 — no WAFv2 WebACL attached by design (cost), so there's nothing to configure an AMR rule group on
  enabled         = true
  is_ipv6_enabled = true
  comment         = "portfolio root+www — Phase 1"
  aliases         = [var.domain_name, "www.${var.domain_name}"]
  price_class     = var.cloudfront_price_class
  http_version    = "http2and3"

  origin {
    domain_name = aws_route53_record.origin.fqdn
    origin_id   = "portfolio-ec2"

    custom_origin_config {
      http_port                = 80
      https_port               = 443
      origin_protocol_policy   = "https-only"
      origin_ssl_protocols     = ["TLSv1.2"]
      origin_keepalive_timeout = 5
      origin_read_timeout      = 30
    }
  }

  default_cache_behavior {
    target_origin_id       = "portfolio-ec2"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true
    cache_policy_id        = "658327ea-f89d-4fab-a63d-7e88639e58f6" # AWS managed: CachingOptimized
  }

  # Let's Encrypt HTTP-01 validation for the apex/www SANs must reach
  # nginx uncached. redirect-to-https (not allow-all) is safe here: the
  # ACME validator follows HTTP->HTTPS redirects per RFC 8555, so this
  # still round-trips to nginx correctly without permitting plaintext
  # HTTP on this path.
  ordered_cache_behavior {
    path_pattern           = "/.well-known/acme-challenge/*"
    target_origin_id       = "portfolio-ec2"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    cache_policy_id        = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad" # AWS managed: CachingDisabled
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.portfolio.certificate_arn
    ssl_support_method       = "sni-only" # dedicated IP (vip) is billed — never use it
    minimum_protocol_version = "TLSv1.2_2021"
  }

  tags = { Name = "portfolio-cloudfront" }
}

resource "aws_ssm_parameter" "portfolio_cloudfront_distribution_id" {
  #checkov:skip=CKV2_AWS_34:Distribution ID is not sensitive — used only for CI cache invalidation targeting
  name  = "/${var.ssm_namespace}/portfolio/cloudfront-distribution-id"
  type  = "String"
  value = aws_cloudfront_distribution.portfolio.id

  tags = { Name = "portfolio-cloudfront-distribution-id" }
}

output "cloudfront_domain_name" {
  value       = aws_cloudfront_distribution.portfolio.domain_name
  description = "Pre-cutover smoke-test target — verify this serves the portfolio correctly before flipping route53.tf's root/www records to alias it"
}
