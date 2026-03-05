# 🚀 Portfolio Infrastructure — rerktserver.com

A **cost-effective**, **secure**, and **fully automated** portfolio website for Edward Rerkphuritat, built with DevSecOps best practices end-to-end.

[![Build & Deploy](https://github.com/rerkted/aws-server/actions/workflows/deploy.yml/badge.svg)](https://github.com/rerkted/aws-server/actions/workflows/deploy.yml)

---

## 🏗️ Architecture

```
Git Push to main
      │
      ▼
GitHub Actions
      │
      ├── 🐳 Docker build (linux/amd64)
      ├── 🔍 Trivy vulnerability scan (blocks on CRITICAL)
      ├── 📦 Push to ECR
      │
      └── 🚀 SSM deploy → EC2 pull & run
                              │
                              ▼
                     nginx:1.27-alpine container
                     HTTPS via Let's Encrypt
                     serving rerktserver.com
```

---

## 💰 Cost Breakdown

| Resource         | Cost       |
|------------------|------------|
| EC2 t3.nano      | ~$3.50/mo  |
| EBS gp3 30GB     | ~$2.40/mo  |
| Elastic IP       | Free while attached |
| ECR (5 images)   | ~$0.05/mo  |
| Data transfer    | ~$0.50/mo  |
| **Total**        | **~$6.50/mo** |

---

## ⚡ Quick Start

### Prerequisites

- AWS CLI configured (`aws configure`)
- Terraform installed (`>= 1.5`)
- Docker installed
- An existing EC2 key pair in AWS
- Domain registered in Route53

### 1. Deploy Infrastructure

```bash
cd terraform

# Copy and fill in your values
cp terraform.tfvars.example terraform.tfvars
nano terraform.tfvars

# Deploy
terraform init
terraform plan
terraform apply
```

### 2. Add GitHub Secrets

Go to your repo → **Settings → Secrets and variables → Actions**:

| Secret | Value |
|--------|-------|
| `AWS_ACCESS_KEY_ID` | IAM user access key |
| `AWS_SECRET_ACCESS_KEY` | IAM user secret key |
| `EC2_INSTANCE_ID` | From `terraform output instance_id` |
| `EC2_PUBLIC_IP` | From `terraform output public_ip` |

### 3. Push to Deploy

```bash
git add .
git commit -m "feat: update portfolio"
git push origin main
# → GitHub Actions automatically builds, scans, and deploys
```

---

## 🏗️ Project Structure

```
aws-server/
├── website/
│   └── index.html              # Portfolio site
├── terraform/
│   ├── main.tf                 # VPC, EC2, ECR, IAM, Route53
│   ├── variables.tf            # Input variables
│   ├── userdata.sh             # EC2 bootstrap — installs Docker, Certbot, issues SSL cert
│   └── terraform.tfvars.example
├── .github/
│   └── workflows/
│       └── deploy.yml          # CI/CD pipeline
├── Dockerfile                  # nginx:1.27-alpine golden image
├── nginx.conf                  # HTTP-only config (used on first boot for ACME challenge)
├── nginx-ssl.conf              # Full HTTPS config (used after cert is issued)
└── README.md
```

---

## 🔐 SSL / HTTPS

Certificates are fully automated via **Let's Encrypt + Certbot** on first EC2 boot:

```
userdata.sh runs on first boot:
  1. Docker installed, ECR image pulled
  2. nginx starts on HTTP port 80 (nginx.conf — no SSL required)
  3. Certbot requests cert via ACME webroot challenge
  4. Cert issued → /etc/letsencrypt/live/rerktserver.com/
  5. Container restarts with HTTPS using nginx-ssl.conf

Auto-renewal (cron, twice daily — 3am & 3pm):
  └── certbot renew → SIGHUP nginx (zero downtime)
```

### Cert expiry safety net

| Event | Timing |
|-------|--------|
| Cert validity | 90 days |
| Auto-renewal trigger | < 30 days remaining |
| Cron schedule | Twice daily (3am, 3pm UTC) |

### Verify on the server

```bash
sudo certbot certificates          # View cert + expiry
sudo certbot renew --dry-run       # Test renewal
sudo tail -f /var/log/syslog | grep certbot
```

---

## 🛡️ Security Features

### Infrastructure
- ✅ EC2 IAM instance role — no hardcoded credentials
- ✅ SSH restricted to your IP only (`your_ip_cidr` in tfvars)
- ✅ SSM-based deployment — no SSH port exposed in CI/CD
- ✅ Encrypted EBS volume (gp3)
- ✅ ECR image scanning on push

### CI/CD Pipeline
- ✅ Trivy vulnerability scanning — blocks deployment on CRITICAL CVEs
- ✅ `apk upgrade` in Dockerfile — patches all OS packages at build time
- ✅ Pinned action versions — prevents supply chain attacks
- ✅ SSM command status verification — detects silent deploy failures
- ✅ 10-minute pipeline timeout

### nginx / HTTPS
- ✅ TLS 1.2 and 1.3 only
- ✅ HSTS with 2-year max-age + includeSubDomains
- ✅ Rate limiting (20 req/s general, 2 req/min contact)
- ✅ Security headers: X-Frame-Options, X-Content-Type-Options, X-XSS-Protection, Referrer-Policy, Permissions-Policy
- ✅ Static asset caching with immutable Cache-Control

### IAM Least Privilege
The `github-actions-portfolio` IAM user has only the minimum permissions needed:
- ECR: push/pull to the `portfolio` repository only
- SSM: send and check commands
- EC2: describe instances

---

## 🔧 Customization

**Change instance type:**
```hcl
# terraform.tfvars
instance_type = "t3.micro"   # $7.50/mo
instance_type = "t3.small"   # $15/mo
```

**Scale up (if traffic grows):**
Replace EC2 with ECS Fargate or add ALB + Auto Scaling — the same Docker image works everywhere.

---

## 🔄 Re-deploying / Rebuilding EC2

If you ever need to destroy and recreate the EC2:

```bash
cd terraform

# Destroy only EC2 and Elastic IP (keeps ECR, VPC, Route53)
terraform destroy \
  -target=aws_eip.portfolio \
  -target=aws_instance.portfolio

# Recreate — userdata.sh runs automatically on first boot
terraform apply
```

After `terraform apply`:
1. Update `EC2_INSTANCE_ID` and `EC2_PUBLIC_IP` in GitHub Secrets
2. Watch bootstrap: `ssh -i ~/.ssh/your-key.pem ec2-user@NEW_IP`
3. `sudo tail -f /var/log/portfolio-bootstrap.log`
4. Wait for `=== Bootstrap complete ===`
5. Re-run GitHub Actions pipeline

---

## 📊 Monitoring (Optional)

```bash
# CloudWatch basic metrics are free
# Add to userdata.sh:
yum install -y amazon-cloudwatch-agent
```

---

## 🌐 Live Site

**[https://rerktserver.com](https://rerktserver.com)**