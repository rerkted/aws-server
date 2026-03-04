# 🚀 Portfolio Infrastructure

A **cost-effective**, **repeatable**, and **fully automated** portfolio website using:
- **Docker** (golden image)
- **AWS ECR** (image registry)
- **AWS EC2 t3.nano** (~$3.50/month)
- **Terraform** (infrastructure as code)
- **GitHub Actions** (CI/CD pipeline)

---

## 💡 Architecture

```
Git Push to main
      │
      ▼
GitHub Actions
      │
      ├── 🐳 docker build  →  ECR push (golden image)
      │
      └── 🚀 SSM deploy  →  EC2 pull & run
                                │
                                ▼
                         nginx:alpine container
                         serving your portfolio
```

**Cost breakdown:**
| Resource | Cost |
|----------|------|
| EC2 t3.nano | ~$3.50/mo |
| Elastic IP | Free while attached |
| ECR (5 images) | ~$0.05/mo |
| Data transfer | ~$0.50/mo |
| **Total** | **~$4/mo** vs ~$35/mo on t2.standard |

---

## ⚡ Quick Start

### 1. Prerequisites
- AWS CLI configured (`aws configure`)
- Terraform installed (`>= 1.5`)
- Docker installed
- An existing EC2 key pair in AWS

### 2. Deploy Infrastructure

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

### 3. Add GitHub Secrets

In your repo → Settings → Secrets:

| Secret | Value |
|--------|-------|
| `AWS_ACCESS_KEY_ID` | IAM user access key |
| `AWS_SECRET_ACCESS_KEY` | IAM user secret key |
| `EC2_INSTANCE_ID` | From terraform output |
| `EC2_PUBLIC_IP` | From terraform output |

### 4. Enable SSM on EC2

The deploy workflow uses AWS SSM instead of SSH (no exposed port 22 needed):

```bash
# Add this policy to the EC2 IAM role (add in main.tf or console):
# arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
```

### 5. Push to Deploy

```bash
git add .
git commit -m "feat: update portfolio"
git push origin main
# → GitHub Actions automatically builds, pushes, and deploys
```

---

## 🏗️ Project Structure

```
portfolio/
├── website/
│   └── index.html          # Your portfolio site
├── terraform/
│   ├── main.tf             # VPC, EC2, ECR, IAM
│   ├── variables.tf        # Input variables
│   └── userdata.sh         # EC2 bootstrap script
├── .github/
│   └── workflows/
│       └── deploy.yml      # Full CI/CD pipeline
├── Dockerfile              # Golden image definition
├── nginx.conf              # Nginx configuration
└── README.md
```

---

## 🔧 Customization

**Change instance type** (for more traffic):
```hcl
# terraform.tfvars
instance_type = "t3.micro"   # $7.50/mo
instance_type = "t3.small"   # $15/mo
```

**Add HTTPS** (recommended):
1. Point your domain to the Elastic IP
2. Add `certbot` to `userdata.sh`
3. Update nginx.conf for SSL termination

**Scale up** (if you go viral):
Replace EC2 with ECS Fargate or add an ALB + Auto Scaling Group — the same Docker image works everywhere.

---

## 🛡️ Security Features

- EC2 instance role (no hardcoded credentials)
- SSH restricted to your IP only
- ECR image scanning on push
- Security headers in nginx
- Encrypted EBS volume
- SSM-based deployment (no SSH in CI/CD)

---

## 📊 Monitoring (Optional, Free Tier)

```bash
# CloudWatch basic metrics are free
# Add to userdata.sh to enable:
yum install -y amazon-cloudwatch-agent
```

---

## 🔐 HTTPS / SSL — rerktserver.com

**No separate repo needed.** Everything is automated in this same repo.

### How cert lifecycle works
```
First EC2 boot (userdata.sh runs automatically):
  1. nginx starts on HTTP port 80
  2. Certbot requests cert from Let's Encrypt
  3. Let's Encrypt hits /.well-known/acme-challenge/ to verify domain ownership
  4. Cert issued → /etc/letsencrypt/live/rerktserver.com/
  5. Container restarts with HTTPS (port 443) + certs mounted read-only

Auto-renewal (cron, twice daily — 3am & 3pm):
  └── certbot renew → renews only if < 30 days remain → SIGHUP nginx (zero downtime)
```

### Cert expiry safety net
| What | When |
|------|------|
| Cert validity | 90 days |
| Auto-renewal trigger | < 30 days remaining |
| Cron schedule | Twice daily |
| Email warning (if renewal fails) | 20 days + 10 days before expiry |
| Nginx reload after renewal | Automatic (zero downtime) |

### Verify on the server
```bash
sudo certbot certificates          # View cert + expiry date
sudo certbot renew --dry-run       # Test renewal without actually renewing
sudo tail -f /var/log/syslog | grep certbot   # Watch renewal logs
```

### DNS requirement
Terraform auto-creates Route53 A records for `rerktserver.com` and `www.rerktserver.com`.
If your domain is at GoDaddy/Namecheap — either transfer DNS to Route53, or manually
create an A record pointing to the Elastic IP from `terraform output public_ip`.
