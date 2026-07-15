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

## ─── CLOUDFRONT DISTRIBUTION — ai.DOMAIN_NAME (Phase 2) ────────
# Separate distribution, not an extension of the one above — two
# independent reasons:
#
# 1. CloudFront does NOT forward the viewer's original Host header to
#    a custom origin by default; it sends the Origin Domain Name
#    instead. nginx picks its server{} block by matching Host against
#    server_name, so every request from the distribution above
#    currently arrives at nginx as Host: origin.DOMAIN_NAME, matches
#    nothing, and falls through to nginx's default block (the first
#    listen 443 ssl; block — the portfolio vhost). That distribution
#    "works" only because portfolio's own content is coincidentally
#    correct for root/www. It would NOT be correct for ai. — without
#    an explicit fix, ai. traffic would silently get served the
#    portfolio homepage instead of the chat UI/API. Fixed here via
#    origin_request_policy_id (Managed-AllViewer) forwarding Host.
# 2. The AWS managed CachingOptimized policy doesn't key its cache on
#    Host. Sharing one distribution/cache behavior between root/www
#    and ai. would mean the first cache miss for path "/" — from
#    EITHER vhost — populates a single entry served to both, even
#    though they have genuinely different content at that path
#    (unlike root vs www, which intentionally serve identical
#    content). Separate distributions never share cache, so this
#    can't happen. Reuses the same ACM cert (one cert can back
#    multiple distributions) and the same origin — cost is a few
#    extra lines, not a new cert or new EC2 resource.

resource "aws_cloudfront_distribution" "ai" {
  #checkov:skip=CKV_AWS_86:Access logging to S3 disabled intentionally — cost avoidance, matches other cost-tradeoff decisions in this repo
  #checkov:skip=CKV_AWS_310:Origin failover not configured — single EC2 origin by design, no second origin to fail over to
  #checkov:skip=CKV_AWS_374:Geo restriction intentionally left open — personal portfolio site, no audience restriction needed
  #checkov:skip=CKV2_AWS_32:Response headers policy not attached — nginx already sets all security headers (HSTS, CSP, X-Frame-Options, etc.) at the origin and CloudFront passes them through unchanged
  #checkov:skip=CKV_AWS_305:Default root object not set — nginx's own try_files/index handling already covers this at the origin
  #checkov:skip=CKV_AWS_68:WAF intentionally out of scope for this rollout — real per-rule/per-request cost, conflicts with the no-additional-cost constraint on this phase. See migration plan.
  #checkov:skip=CKV2_AWS_47:Same reasoning as CKV_AWS_68 — no WAFv2 WebACL attached by design (cost), so there's nothing to configure an AMR rule group on
  enabled         = true
  is_ipv6_enabled = true
  comment         = "ai chat — Phase 2"
  aliases         = ["ai.${var.domain_name}"]
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

  # Serves the static chat UI. origin_request_policy_id is required —
  # see the Host-forwarding note above; without it this vhost would
  # silently serve the portfolio homepage instead.
  default_cache_behavior {
    target_origin_id         = "portfolio-ec2"
    viewer_protocol_policy   = "redirect-to-https"
    allowed_methods          = ["GET", "HEAD"]
    cached_methods           = ["GET", "HEAD"]
    compress                 = true
    cache_policy_id          = "658327ea-f89d-4fab-a63d-7e88639e58f6" # AWS managed: CachingOptimized
    origin_request_policy_id = "216adef6-5c7f-47e4-b989-5492eafa07d3" # AWS managed: Managed-AllViewer (forwards Host)
  }

  # Dynamic, Lambda-backed proxy — never cached. POST requires the
  # full 7-method set; CloudFront/the provider only accept GET/HEAD,
  # GET/HEAD/OPTIONS, or all seven, no cherry-picking. https-only (not
  # redirect-to-https): this is fetch()/XHR traffic, not
  # browser-navigable, so a hard reject of plaintext HTTP is more
  # correct than a redirect-then-retry. origin_request_policy_id is
  # needed here too, so Content-Type: application/json and Host both
  # reach nginx — CloudFront forwards POST bodies automatically once
  # POST is allowed, that part isn't policy-gated.
  ordered_cache_behavior {
    path_pattern             = "/api/*"
    target_origin_id         = "portfolio-ec2"
    viewer_protocol_policy   = "https-only"
    allowed_methods          = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods           = ["GET", "HEAD"]
    cache_policy_id          = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad" # AWS managed: CachingDisabled
    origin_request_policy_id = "216adef6-5c7f-47e4-b989-5492eafa07d3" # AWS managed: Managed-AllViewer
  }

  # Ordered cache behaviors are per-distribution — this needs its own
  # copy, not inherited from the portfolio distribution above.
  # ai.DOMAIN_NAME is already a SAN on the certbot/origin cert, so this
  # keeps its renewal working through CloudFront the same way already
  # proven for root/www.
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

  tags = { Name = "ai-cloudfront" }
}

resource "aws_ssm_parameter" "ai_cloudfront_distribution_id" {
  #checkov:skip=CKV2_AWS_34:Distribution ID is not sensitive — used only for CI cache invalidation targeting
  name  = "/${var.ssm_namespace}/ai/cloudfront-distribution-id"
  type  = "String"
  value = aws_cloudfront_distribution.ai.id

  tags = { Name = "ai-cloudfront-distribution-id" }
}

output "ai_cloudfront_domain_name" {
  value       = aws_cloudfront_distribution.ai.domain_name
  description = "Pre-cutover smoke-test target — curl with -H \"Host: ai.DOMAIN_NAME\" to verify the ai. vhost (not the portfolio homepage) is served before flipping chat.tf's ai record to alias it"
}
