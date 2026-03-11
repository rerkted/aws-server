# Portfolio Infrastructure — rerktserver.com

A cost-effective, secure, and fully automated portfolio website built with DevSecOps best practices end-to-end.

[![Build & Deploy](https://github.com/rerkted/aws-server/actions/workflows/deploy.yml/badge.svg)](https://github.com/rerkted/aws-server/actions/workflows/deploy.yml)

---

## Architecture

```
Git Push to main
      │
      ▼
GitHub Actions (OIDC — no static AWS keys)
      │
      ├── Docker build (linux/amd64)
      ├── Trivy vulnerability scan (blocks on CRITICAL)
      ├── Push to ECR
      │
      └── SSM deploy → EC2 pull & run
                              │
                              ▼
                     portfolio   → nginx reverse proxy (rerktserver.com)
                     rerkt-ai    → Claude API proxy (ai.rerktserver.com)
                     bedrock-ai  → AWS Bedrock proxy (bedrock.rerktserver.com)
                     HTTPS via Let's Encrypt
```

---

## Cost Breakdown

| Resource | Cost |
|----------|------|
| EC2 t3.nano | ~$3.50/mo |
| EBS gp3 30GB | ~$2.40/mo |
| Elastic IP | Free while attached |
| ECR (images) | ~$0.05/mo |
| Data transfer | ~$0.50/mo |
| **Total** | **~$6.50/mo** |

---

## Quick Start

### Prerequisites

- AWS CLI configured (`aws configure`)
- Terraform installed (`>= 1.5`)
- Docker installed
- An existing EC2 key pair in AWS
- Domain registered in Route53

### 1. Deploy aws-server first (required — stores EIP in SSM for Grafana)

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
vi terraform.tfvars   # fill in your values

terraform init
terraform apply
```

### 2. Add GitHub Secrets

Go to your repo → **Settings → Secrets and variables → Actions**:

| Secret | Description |
|--------|-------------|
| `AWS_OIDC_ROLE_ARN` | From `terraform output oidc_role_arn` |
| `ANTHROPIC_API_KEY` | Anthropic API key for rerkt-ai container |

No static AWS keys, no instance IDs, no IPs — all handled via OIDC and SSM Parameter Store.

### 3. Push to Deploy

```bash
git push origin main
# GitHub Actions automatically builds, scans, and deploys
```

---

## Project Structure

```
aws-server/
├── website/
│   └── index.html              # Portfolio site
├── chat/                       # Rerkt.AI proxy (Claude API)
├── bedrock/                    # Bedrock AI proxy (AWS Bedrock)
├── terraform/
│   ├── main.tf                 # Provider, backend
│   ├── vpc.tf                  # VPC, subnet, routing
│   ├── ec2.tf                  # EC2, EIP, SSM parameters
│   ├── ecr.tf                  # ECR repositories
│   ├── iam.tf                  # EC2 instance role
│   ├── oidc.tf                 # GitHub Actions OIDC federation
│   ├── security.tf             # Security group
│   ├── route53.tf              # DNS records
│   ├── userdata.sh             # EC2 bootstrap script
│   ├── variables.tf            # Input variables
│   └── terraform.tfvars.example
├── .github/
│   └── workflows/
│       └── deploy.yml          # CI/CD pipeline
├── Dockerfile                  # nginx:1.27-alpine golden image
├── nginx.conf                  # HTTP-only config (ACME challenge)
├── nginx-ssl.conf              # Full HTTPS config
└── RUNBOOK.md                  # Operational procedures
```

---

## SSL / HTTPS

Certificates are fully automated via Let's Encrypt + Certbot on first EC2 boot:

```
userdata.sh runs on first boot:
  1. Docker installed, ECR image pulled
  2. nginx starts on HTTP port 80 (ACME challenge)
  3. Certbot requests cert via webroot challenge
  4. Cert issued → /etc/letsencrypt/live/rerktserver.com/
  5. Container restarts with HTTPS using nginx-ssl.conf

Auto-renewal (cron, twice daily — 3am & 3pm UTC):
  └── certbot renew → SIGHUP nginx (zero downtime)
```

---

## Security

### Infrastructure
- EC2 IAM instance role — no hardcoded credentials
- SSH restricted to your IP only (`your_ip_cidr` in tfvars)
- SSM-based deployment — no SSH in CI/CD pipeline
- Encrypted EBS volume (gp3)

### CI/CD Pipeline
- GitHub Actions OIDC federation — no static AWS access keys
- Instance ID and public IP read from SSM Parameter Store at runtime — no secrets to rotate
- Trivy vulnerability scanning — blocks on CRITICAL CVEs
- `apk upgrade` in Dockerfile — patches OS packages at build time
- Pinned action versions — prevents supply chain attacks

### nginx / HTTPS
- TLS 1.2 and 1.3 only
- HSTS with 2-year max-age + includeSubDomains
- Rate limiting (20 req/s general, 2 req/min contact form)
- Security headers: X-Frame-Options, X-Content-Type-Options, X-XSS-Protection, Referrer-Policy, Permissions-Policy

### IAM Least Privilege

The GitHub Actions OIDC role (`github-actions-oidc-role`) has only:
- ECR: push/pull to portfolio repositories
- SSM: send commands, get command status, read parameters
- EC2: describe instances

No long-lived access keys. GitHub requests a short-lived token scoped to the repo + branch at runtime via OIDC federation.

---

## SSM Parameter Store

Terraform writes these parameters automatically on every `apply`:

| Parameter | Value | Used by |
|-----------|-------|---------|
| `/rerktserver/portfolio/eip` | Portfolio Elastic IP | aws-grafana security group |
| `/rerktserver/portfolio/instance-id` | EC2 instance ID | GitHub Actions deploy workflow |

The deploy workflow reads the instance ID from SSM at runtime — no manual secret updates needed when infrastructure is rebuilt.

---

## Monitoring

Log and metrics observability is handled by the optional companion [aws-grafana](https://github.com/rerkted/aws-grafana) stack:

- **Grafana** dashboard at [grafana.rerktserver.com](https://grafana.rerktserver.com)
- **Promtail** runs as a systemd service, shipping logs to Loki — auto-starts when grafana is up, auto-stops when grafana is destroyed (managed by `sync-loki-url.timer`)
- **node-exporter** runs continuously on port 9100, exposing host metrics for Prometheus to scrape when grafana is active
- Logs collected: Docker container stdout, journald auth logs via `sshd.service` (SSH/CSPM), journald system logs

> Grafana is optional — the portfolio site runs independently. See [RUNBOOK.md](RUNBOOK.md) for instructions on spinning grafana up/down.

---

## Live Site

**[https://rerktserver.com](https://rerktserver.com)**
