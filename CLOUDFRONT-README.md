# 🌐 Multi-Distribution CloudFront CDN

## Phased, Zero-Downtime Migration to a CDN-Fronted Origin

---

## Overview

This document details migrating three independently-behaving vhosts (a static
portfolio, a Lambda-backed AI chat widget, and a WebSocket-based infrastructure
agent) from direct EC2 exposure to AWS CloudFront — in four incremental phases,
each shipped and verified in production before the next began, with zero
downtime and zero added monthly cost.

**Before:** All traffic hits a single `t3.nano` EC2 instance directly. No CDN,
no DDoS absorption, no origin protection — the server's IP is the only thing
standing between the internet and nginx.
**After:** Three CloudFront distributions front the same origin. The EC2
instance's real IP is unreachable on HTTPS from anywhere except CloudFront's
own edge network. Static content is cached at the edge; dynamic traffic
(chat API, WebSocket) passes through with correct security controls intact.

---

## The Problem

A single small EC2 instance serving production traffic directly has no layer
between the public internet and the origin:

- No DDoS absorption — a traffic spike or attack hits the box directly, and a
  `t3.nano` (512MB RAM) has essentially no headroom to absorb one
- No edge caching — every request, including static assets, round-trips to
  origin
- No way to protect the origin even after adding other controls (IP
  allowlists, rate limits) — anyone who finds the EC2 instance's IP can hit
  it directly, bypassing whatever's in front of it

The fix is a CDN — but a real one, not a checkbox. Getting it right meant
solving three non-obvious problems along the way (below), not just pointing
DNS at a distribution and calling it done.

---

## The Solution — Architecture

```
                              Browser
                                 │
                 ┌───────────────┼───────────────┐
                 ▼               ▼               ▼
        CloudFront Dist.  CloudFront Dist.  CloudFront Dist.
        (root + www)      (ai. — chat)      (agent. — WebSocket)
        CachingOptimized  Host-forward fix  Host-forward fix
                 │               │          + origin-verify secret
                 └───────────────┼───────────────┘
                                 │  HTTPS only, CloudFront
                                 │  origin-facing IPs only
                                 ▼
                    ┌─────────────────────────┐
                    │   EC2 (t3.nano) — nginx │
                    │  SG: port 443 locked to │
                    │  CloudFront prefix list │
                    └────────────┬────────────┘
                                 │
                 ┌───────────────┼───────────────┐
                 ▼               ▼               ▼
          Static files    Lambda Function   FastAPI + WebSocket
          (portfolio)     URL (chat-ai)     (agent-ai, IP-allowlisted
                                              + origin-verify header)
```

Each distribution is independent — different content, different caching
needs, different risk profile — but all share one ACM certificate and one
origin, keeping the added infrastructure minimal.

---

## Implementation

### Phase 1 — ACM certificate + first distribution (root/www)

Lowest-risk slice first: the one vhost with no IP-based access control to
break. New `origin.<domain>` DNS record, used only as CloudFront's origin
name (can't reuse the public domain — circular). Origin's existing Let's
Encrypt certificate just needed one more SAN added; no new TLS cert was
required at the origin.

```hcl
resource "aws_cloudfront_distribution" "portfolio" {
  aliases     = [var.domain_name, "www.${var.domain_name}"]
  price_class = "PriceClass_100"   # bounds cost even under traffic spikes

  default_cache_behavior {
    cache_policy_id        = "658327ea-f89d-4fab-a63d-7e88639e58f6" # CachingOptimized
    viewer_protocol_policy = "redirect-to-https"
  }
  # ...
}
```

### Phase 2 — Chat widget, and a Host-header bug caught before it shipped

**The non-obvious catch:** CloudFront does not forward the viewer's original
`Host` header to a custom origin by default — it sends its own configured
Origin Domain Name instead. nginx routes to the correct vhost by matching
`Host` against `server_name`. Phase 1 "worked" only because nginx's
*default* fallback block happened to be the correct content for root/www.
It would **not** have been correct for the chat widget — without an explicit
fix, `ai.<domain>` traffic would have silently served the portfolio homepage
instead of the chat UI.

Fix: an `origin_request_policy_id` (AWS managed `Managed-AllViewer`)
forwarding `Host` correctly, on a **separate** distribution rather than
extending Phase 1's — sharing one distribution's cache behavior across vhosts
with different content at the same path (`/`) would also have caused a
cache-key collision, since CloudFront's optimized caching policy doesn't key
on `Host`.

Also required: nginx's `realip` module, trusting CloudFront's published IP
ranges (refreshed at deploy time from `ip-ranges.json`), so rate-limiting
and per-IP logic see the real visitor — not CloudFront's edge IP — once
CloudFront sits in front.

### Phase 3 — WebSocket support + defense-in-depth

The infrastructure agent's WebSocket chat interface needed its own
distribution behavior (`CachingDisabled`, full header forwarding for the
`Sec-WebSocket-*` handshake family). Verified against AWS's actual current
documentation rather than assumption: CloudFront applies a dedicated
10-minute idle-connection allowance to established WebSocket connections,
independent of the general origin-response timeout — no special
configuration or support ticket needed for a normal chat session.

This endpoint also has real infrastructure-mutating IAM permissions (EC2
start/stop, security group rule changes) behind a single-IP nginx allowlist
— a materially higher-stakes profile than the chat widget. Added a second,
independent layer: a random secret CloudFront alone attaches to origin
requests (an `origin.custom_header`, invisible to viewers), checked by nginx
alongside the IP allowlist. Anyone reaching this endpoint now needs to be
*both* on the allowlisted IP *and* routed through this specific CloudFront
distribution — closing the gap where the allowlisted IP itself might become
reachable from an unexpected network path (e.g. carrier-grade NAT).

### Phase 4 — Locking down the origin, and a near-miss caught in review

With all three vhosts behind CloudFront, the last step was restricting the
EC2 security group so the origin is unreachable except from CloudFront's own
IP range — closing the direct-bypass gap the earlier phases deliberately
left open.

```hcl
data "aws_ec2_managed_prefix_list" "cloudfront_origin_facing" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

ingress {
  from_port       = 443
  to_port         = 443
  prefix_list_ids = [data.aws_ec2_managed_prefix_list.cloudfront_origin_facing.id]
}
```

**The near-miss:** the original scope called for locking down port 80 too.
Design review caught that this would have silently broken certificate
renewal roughly 60–90 days later — Let's Encrypt's own validators, which
have no stable published IP range, validate one SAN (`origin.<domain>`,
CloudFront's own origin name) directly against the EC2 instance on port 80,
bypassing CloudFront entirely by necessity. Restricting port 80 would have
failed that one SAN's authorization, which fails the *entire* multi-SAN
renewal, which — since all three distributions share one origin certificate
— would eventually have taken all three down simultaneously when it expired.
Port 80 was deliberately left open; only 443 is restricted. Verified with a
live `certbot renew --dry-run` immediately after applying, rather than
waiting three months to find out.

---

## Security Comparison

| Property | Direct EC2 | CloudFront-fronted |
|---|---|---|
| Origin IP directly reachable (HTTPS) | Yes, from anywhere | No — CloudFront IPs only |
| DDoS absorption | None | AWS Shield Standard, automatic |
| Edge caching | None | Static assets cached at edge |
| Rate limiting basis | N/A | Real client IP (via `realip` + `X-Forwarded-For`) |
| WebSocket support | Direct only | Full support, dedicated idle-timeout handling |
| Defense-in-depth on sensitive endpoint | IP allowlist only | IP allowlist + CloudFront-only secret header |
| Monthly cost | ~$6.50 (unchanged) | ~$6.50 (CloudFront within Always Free tier) |

---

## Verification

Confirm a response actually came through CloudFront (not a caching artifact
of your own browser):

```bash
curl -sI https://yourdomain.com/ | grep -iE "x-cache|via|x-amz-cf"
# via: 1.1 <hash>.cloudfront.net (CloudFront)
# x-cache: Hit from cloudfront
# x-amz-cf-pop: <edge location code>
```

Confirm the origin is actually locked down (should fail to connect, not just
get rejected at the application layer):

```bash
curl -sk --max-time 5 https://<origin-EIP>/health
# curl: (28) Connection timed out — proof the security group is enforcing
```

Confirm certificate renewal survived the security group change:

```bash
sudo certbot renew --dry-run
# Congratulations, all simulated renewals succeeded
```

---

## Enterprise Context

This is the same pattern used to front production workloads at scale —
multi-origin CDN architecture, defense-in-depth beyond a single access
control layer, and treating a security-group change with the same rollback
discipline as an application deploy. Key considerations that transfer
directly to client work:

- **Phased rollout over big-bang cutover** — each phase was independently
  shippable and independently rollback-able (a single DNS record revert),
  keeping blast radius small at every step
- **Design review before infrastructure changes ship** — both non-obvious
  bugs in this migration (the Host-forwarding gap, the port-80 renewal
  near-miss) were caught by deliberately reviewing the design before
  applying it, not discovered in production
- **Verification over assumption** — every claim in this document (the
  WebSocket idle-timeout allowance, the origin protocol behavior, the
  security group's actual enforcement) was checked against AWS's current
  documentation or tested live, not taken on faith from training data or a
  tutorial

---

## Files

| File | Purpose |
|---|---|
| `terraform/cloudfront.tf` | All three distributions, ACM certificate, origin-verify secret |
| `terraform/security.tf` | Security group restriction, CloudFront origin-facing prefix list |
| `terraform/route53.tf`, `chat.tf`, `agent.tf` | DNS alias records pointing at each distribution |
| `nginx-ssl.conf` | `realip` module config, origin-verify header check |
| `.github/workflows/deploy.yml` | CloudFront IP-range refresh, cache invalidation, health checks |

---

## References

- [AWS — Request and response behavior for custom origins](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/RequestAndResponseBehaviorCustomOrigin.html)
- [AWS — Origin settings (response/keep-alive timeout quotas)](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/DownloadDistValuesOrigin.html)
- [AWS — CloudFront quotas, including the WebSocket idle-connection allowance](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/cloudfront-limits.html)
