# From Zero to Deployed: Complete Setup Guide

This guide walks you through deploying your own portfolio infrastructure from scratch — from creating an AWS account to having a live site with automatic CI/CD. No prior cloud experience required.

**What you're building:** A portfolio website running on a single EC2 instance behind nginx, with HTTPS via Let's Encrypt, automated deployments via GitHub Actions, and optional AI chat features. ~$6.50/month.

---

## Table of Contents

1. [Cost Estimate](#1-cost-estimate)
2. [Install Required Tools](#2-install-required-tools)
3. [Create an AWS Account](#3-create-an-aws-account)
4. [Get a Domain Name](#4-get-a-domain-name)
5. [Fork and Clone the Repo](#5-fork-and-clone-the-repo)
6. [Customize Your Portfolio Content](#6-customize-your-portfolio-content)
7. [One-Time AWS Setup](#7-one-time-aws-setup)
8. [Configure Terraform](#8-configure-terraform)
9. [Deploy Your Infrastructure](#9-deploy-your-infrastructure)
10. [Connect GitHub Actions](#10-connect-github-actions)
11. [Trigger Your First Deploy](#11-trigger-your-first-deploy)
12. [Verify Your Site is Live](#12-verify-your-site-is-live)
13. [Optional: Add Grafana Monitoring](#13-optional-add-grafana-monitoring)
14. [Day-to-Day Operations](#14-day-to-day-operations)
15. [Troubleshooting](#15-troubleshooting)

---

## 1. Cost Estimate

All costs are monthly. These fit within AWS's free tier for the first 12 months (EC2 t3.nano is **not** free tier — t2.micro is, but it's weaker).

| Resource | Monthly Cost |
|----------|-------------|
| EC2 t3.nano | ~$3.50 |
| EBS 30GB gp3 | ~$2.40 |
| Elastic IP | Free (while attached to running instance) |
| ECR (Docker images) | ~$0.05 |
| Route53 hosted zone | ~$0.50 |
| Data transfer | ~$0.50 |
| **Total** | **~$7/mo** |

> **Want cheaper?** Set `instance_type = "t3.nano"` in your tfvars (default). The AI chat features require at least t3.nano. If you remove the AI containers, a t3.nano works fine.

---

## 2. Install Required Tools

You need four tools on your computer. Click the links for official installers.

### Git

**What it is:** Version control — how you push code to GitHub to trigger deployments.

- **Mac:** `git` comes pre-installed. Open Terminal and run `git --version` to confirm.
- **Windows:** Download from [git-scm.com](https://git-scm.com/download/win) — install with all defaults.
- **Linux:** `sudo apt install git` (Ubuntu/Debian) or `sudo yum install git` (Amazon Linux/RHEL)

Verify: `git --version` → should print something like `git version 2.x.x`

---

### AWS CLI

**What it is:** Command-line tool for interacting with AWS. Terraform and deploy scripts use this.

**Mac (Homebrew):**
```bash
brew install awscli
```

**Mac (direct download):**
```bash
curl "https://awscli.amazonaws.com/AWSCLIV2.pkg" -o "AWSCLIV2.pkg"
sudo installer -pkg AWSCLIV2.pkg -target /
```

**Windows:** Download the MSI installer from [AWS CLI install page](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)

**Linux:**
```bash
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install
```

Verify: `aws --version` → should print `aws-cli/2.x.x`

---

### Terraform

**What it is:** Infrastructure as Code tool — it creates your AWS resources (EC2, VPC, DNS, IAM, etc.) from code.

**Mac (Homebrew):**
```bash
brew tap hashicorp/tap
brew install hashicorp/tap/terraform
```

**Windows / Linux:** Download from [terraform.io/downloads](https://developer.hashicorp.com/terraform/downloads) — pick your OS, unzip, add to PATH.

Verify: `terraform --version` → should print `Terraform v1.x.x`

---

### Code Editor (Recommended: VSCode)

**What it is:** Where you'll edit your portfolio HTML and config files.

Download from [code.visualstudio.com](https://code.visualstudio.com). Install the **HashiCorp Terraform** extension for syntax highlighting.

> **No editor needed if:** You're comfortable with vim/nano in terminal.

---

## 3. Create an AWS Account

1. Go to [aws.amazon.com](https://aws.amazon.com) → **Create an AWS Account**
2. Enter your email, choose an account name, and set a root password
3. Enter a credit card (required even for free tier — you won't be charged if you stay within limits)
4. Complete phone verification
5. Choose **Basic support** (free)

### Enable Billing Alerts (Recommended)

Protect yourself from unexpected charges:

1. Log into AWS Console → search for **Billing** in the top search bar
2. Go to **Billing preferences** → enable **Receive Free Tier Usage Alerts** and **Receive Billing Alerts**
3. Go to **CloudWatch** → **Alarms** → **Create Alarm** → set an alert at $10/month

### Create an IAM User for CLI Access

**Do not use your root account for day-to-day work.**

1. In AWS Console → search **IAM** → **Users** → **Create user**
2. Username: `terraform-admin` (or any name)
3. Check **Provide user access to the AWS Management Console** if you want console login
4. Permissions: **Attach policies directly** → select **AdministratorAccess**
   > For production use, scope permissions down later. AdministratorAccess is fine for initial setup.
5. Create the user → go to the user → **Security credentials** tab → **Create access key**
6. Choose **CLI** → download the CSV or copy the **Access key ID** and **Secret access key**

### Configure AWS CLI

```bash
aws configure
```

Enter when prompted:
```
AWS Access Key ID:     <paste your access key>
AWS Secret Access Key: <paste your secret key>
Default region name:   us-east-1
Default output format: json
```

Verify it works:
```bash
aws sts get-caller-identity
```
You should see your account ID and username — not an error.

---

## 4. Get a Domain Name

You need a domain registered in **AWS Route53**. This repo manages DNS records automatically via Terraform.

### Option A: Register a new domain in Route53

1. AWS Console → search **Route53** → **Register domains**
2. Search for your domain → add to cart → checkout
3. Cost: ~$12/year for `.com`
4. A **hosted zone** is created automatically

### Option B: Transfer an existing domain to Route53

1. AWS Console → Route53 → **Transfer domain**
2. Follow the prompts — you'll need an authorization code from your current registrar

### Option C: Use Route53 just for DNS (domain registered elsewhere)

1. AWS Console → Route53 → **Hosted zones** → **Create hosted zone**
2. Enter your domain name → type **Public hosted zone** → Create
3. Copy the 4 **NS (nameserver)** records shown
4. Go to your domain registrar (GoDaddy, Namecheap, etc.) → update nameservers to the 4 Route53 NS records
5. DNS propagation takes 24-48 hours

> **Verify your hosted zone exists:** In Route53 → Hosted zones, you should see your domain listed with an NS record and SOA record.

---

## 5. Fork and Clone the Repo

### Fork on GitHub

1. Go to the repo on GitHub
2. Click **Fork** (top right) → **Create fork**
3. This creates `your-username/aws-server` under your account

> **Why fork?** GitHub Actions runs on your fork, and the OIDC trust policy will be scoped to your GitHub username.

### Clone to your computer

```bash
# Replace YOUR_USERNAME with your GitHub username
git clone https://github.com/YOUR_USERNAME/aws-server.git
cd aws-server
```

### Open in VSCode (optional)

```bash
code .
```

---

## 6. Customize Your Portfolio Content

Your portfolio HTML is in [website/index.html](website/index.html). It uses `YOUR_*` placeholder strings throughout — replace them with your real information.

### Open the file

```bash
# In VSCode:
code website/index.html

# Or in terminal with nano:
nano website/index.html
```

### What to replace

Use **Find & Replace** (`Cmd+H` on Mac, `Ctrl+H` on Windows) to replace each placeholder:

| Placeholder | Replace with | Example |
|-------------|-------------|---------|
| `YOUR_NAME` | Your full name | `Jane Smith` |
| `YOUR_FIRST_NAME` | Your first name | `Jane` |
| `YOUR_LAST_NAME` | Your last name | `Smith` |
| `YOUR_INITIALS` | Your initials (used in logo) | `JS` |
| `YOUR_TITLE` | Your job title | `Cloud Engineer` |
| `YOUR_TAGLINE` | Short tagline | `Building reliable infrastructure at scale` |
| `YOUR_SPECIALIZATION` | What you specialize in | `AWS \| DevSecOps \| IaC` |
| `YOUR_EMAIL` | Your email address | `jane@example.com` |
| `YOUR_LINKEDIN_USERNAME` | Your LinkedIn handle | `janesmith` |
| `YOUR_GITHUB_ORG` | Your GitHub username | `janesmith` |
| `YOUR_FORMSPREE_ID` | Formspree form ID (see below) | `xpwzabcd` |
| `YOUR_YEARS` | Years of experience | `5+` |
| `YOUR_CLOUD_COUNT` | Cloud projects count stat | `20+` |
| `YOUR_CERT_COUNT` | Number of certifications | `4` |

Fill in the rest of the `YOUR_*` placeholders for your bio, skills, projects, experience, and certifications — the HTML comments in the file explain each section.

### Set up the contact form (Formspree)

The contact form uses [Formspree](https://formspree.io) — free up to 50 submissions/month, no backend required.

1. Go to [formspree.io](https://formspree.io) → Sign up (free)
2. **New Form** → give it a name → copy the form ID from the URL or the embed code
   - The ID looks like `xpwzabcd` (8 characters after `/f/`)
3. Replace `YOUR_FORMSPREE_ID` in `index.html` with your form ID

### Commit your changes

```bash
git add website/index.html
git commit -m "feat: add my portfolio content"
# Don't push yet — we'll push after setting up GitHub Actions
```

---

## 7. One-Time AWS Setup

These are manual steps you do once in the AWS Console.

### Create an EC2 Key Pair

This is your SSH key to connect to the server if you ever need to debug directly.

1. AWS Console → search **EC2** → **Key Pairs** (left sidebar, under Network & Security)
2. **Create key pair**
   - Name: `portfolio-key` (or any name — you'll put this in tfvars)
   - Type: **RSA**
   - Format: **.pem** (Mac/Linux) or **.ppk** (Windows with PuTTY)
3. The `.pem` file downloads automatically — **save it somewhere safe** (e.g., `~/.ssh/portfolio-key.pem`)
4. Set permissions on Mac/Linux:
   ```bash
   chmod 400 ~/.ssh/portfolio-key.pem
   ```

> If you lose this file you can't SSH into the server, but the site will still run fine. You'd just need to create a new key pair and recreate the EC2 instance.

### Find Your Home IP Address

The security group restricts SSH to your IP only (best practice — prevents brute force attacks).

```bash
curl ifconfig.me
```

Note the IP — you'll need it in the next step as `YOUR.IP.HERE/32` (add `/32` at the end).

> **Your IP changes if:** You restart your router or switch networks. If SSH stops working later, this is the first thing to check. See [Day-to-Day Operations](#14-day-to-day-operations) for how to update it.

---

## 8. Configure Terraform

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
```

Now edit `terraform.tfvars`:

```bash
# Mac/Linux:
nano terraform.tfvars   # or: code terraform.tfvars

# Windows:
notepad terraform.tfvars
```

Fill in all the required values:

```hcl
# ── Required ──────────────────────────────────────────────────
aws_region    = "us-east-1"              # AWS region — keep us-east-1 unless you have a reason to change
domain_name   = "yourdomain.com"         # Your domain — must exist as a Route53 hosted zone
admin_email   = "you@example.com"        # Email for Let's Encrypt expiry notifications
key_pair_name = "portfolio-key"          # Name of the key pair you created in step 7
your_ip_cidr  = "1.2.3.4/32"            # Your home IP + /32 from step 7
github_org    = "your-github-username"   # Your GitHub username (case-sensitive)

# ── Sensitive — use an env var instead ────────────────────────
# Don't put your API key in this file.
# Set it as an environment variable before running terraform:
#   export TF_VAR_anthropic_api_key="sk-ant-..."
# Get a key at: https://console.anthropic.com
#
# If you don't want the AI chat feature, you still need to set something:
#   export TF_VAR_anthropic_api_key="placeholder"

# ── Optional — defaults are fine ──────────────────────────────
environment    = "production"
instance_type  = "t3.nano"      # t3.nano ~$3.50/mo — cheapest that runs this stack
github_repo    = "aws-server"   # Your fork's repo name (default: aws-server)
grafana_repo   = "aws-grafana"  # Companion monitoring repo name
ssm_namespace  = "myproject"    # Short name used as a prefix for all SSM parameters
grafana_active = false          # Keep false until you deploy aws-grafana separately
```

> **Never commit `terraform.tfvars`** — it's in `.gitignore` already. It contains your home IP and will contain sensitive values.

### Set the Anthropic API key as an env var

```bash
# Mac/Linux — add to your shell profile (~/.zshrc or ~/.bashrc) to persist across sessions:
export TF_VAR_anthropic_api_key="sk-ant-api03-..."

# Reload your shell after adding to profile:
source ~/.zshrc
```

> **Don't have an Anthropic API key?** The AI chat containers (`rerkt-ai`, `bedrock-ai`) are optional. You can set a placeholder value and the infrastructure will still deploy — the AI endpoints just won't work.
> ```bash
> export TF_VAR_anthropic_api_key="placeholder-not-used"
> ```

---

## 9. Deploy Your Infrastructure

Make sure you're in the `terraform/` directory:

```bash
cd terraform   # if not already there
```

### Initialize Terraform

Downloads the AWS provider plugin. Only needed once (or when provider versions change):

```bash
terraform init
```

You should see: `Terraform has been successfully initialized!`

### Preview what will be created

```bash
terraform plan
```

This shows everything Terraform *will* create without actually doing it. Review it — you should see ~20-25 resources being created (VPC, EC2, ECR, IAM roles, Route53 records, etc.).

> **Common error here:** `Error: No hosted zone found for domain` — means your Route53 hosted zone doesn't exist yet. Go back to [Step 4](#4-get-a-domain-name).

### Apply (create the infrastructure)

```bash
terraform apply
```

Type `yes` when prompted. This takes **3-5 minutes**.

When complete, you'll see outputs like:
```
Outputs:
ecr_registry       = "123456789.dkr.ecr.us-east-1.amazonaws.com"
instance_id        = "i-0abc123def456"
oidc_role_arn      = "arn:aws:iam::123456789:role/github-actions-oidc-role"
public_ip          = "54.123.45.67"
```

**Copy the `oidc_role_arn` value** — you'll need it in the next step.

### Back up your terraform.tfstate

```bash
# The state file tracks what Terraform created — losing it makes cleanup much harder
cp terraform.tfstate terraform.tfstate.backup
```

> Terraform does not use an S3 backend by default (it's commented out in `main.tf`). Keep this file safe and backed up. See the comment in `main.tf` if you want to enable S3 remote state.

---

## 10. Connect GitHub Actions

GitHub Actions needs permission to push Docker images to ECR and deploy to your EC2. This is done via **OIDC** — no static AWS keys required.

### Add the OIDC Role ARN as a GitHub Secret

1. Go to your forked repo on GitHub: `github.com/YOUR_USERNAME/aws-server`
2. **Settings** → **Secrets and variables** → **Actions** → **New repository secret**
3. Name: `AWS_OIDC_ROLE_ARN`
4. Value: paste the `oidc_role_arn` from `terraform output` (e.g., `arn:aws:iam::123456789:role/github-actions-oidc-role`)
5. Click **Add secret**

That's the only secret required. Everything else (instance ID, IP, API key) is read from SSM Parameter Store at runtime automatically.

### Add GitHub Repository Variables

These tell the pipeline which SSM namespace and domain to use. Go to the same **Settings → Secrets and variables → Actions** page, but click the **Variables** tab (not Secrets):

| Variable | Value | Description |
|----------|-------|-------------|
| `SSM_NAMESPACE` | `myproject` | Must match `ssm_namespace` in your tfvars |
| `DOMAIN_NAME` | `yourdomain.com` | Your root domain |
| `AI_IMAGE_NAME` | `chat-ai` | Must match `ai_image_name` in your tfvars — ECR repo name for the AI chat proxy |

> **Why variables and not secrets?** These aren't sensitive — they're just config. Variables are visible in logs which makes debugging easier.

### Create a GitHub Environment (Required for Deploy Stage)

The deploy job requires a `production` environment:

1. **Settings** → **Environments** → **New environment**
2. Name: `production`
3. Click **Configure environment** → leave protection rules empty for now → **Save protection rules**

### Update the deploy workflow to point to your devsecops-pipeline fork

The security/verify/cleanup/done stages reference a shared pipeline repo. **You must update these lines** in [.github/workflows/deploy.yml](.github/workflows/deploy.yml) to point to your fork or the original repo:

```yaml
# Find these lines and update the org if you've forked devsecops-pipeline:
uses: rerkted/devsecops-pipeline/.github/workflows/security.yml@main
uses: rerkted/devsecops-pipeline/.github/workflows/dast.yml@main
uses: rerkted/devsecops-pipeline/.github/workflows/cleanup.yml@main
uses: rerkted/devsecops-pipeline/.github/workflows/done.yml@main
```

> **If you haven't forked devsecops-pipeline:** Leave these as-is to use the shared pipeline, or remove those stages entirely and keep just the build + deploy jobs.

---

## 11. Trigger Your First Deploy

### Wait for EC2 bootstrap to complete first

When Terraform created your EC2 instance, it started running a bootstrap script (`userdata.sh`) in the background. This script installs Docker, requests an SSL certificate from Let's Encrypt, and starts the containers. It takes **5-10 minutes**.

Check the progress:

```bash
# SSH into your server (replace with your actual IP from terraform output):
ssh -i ~/.ssh/portfolio-key.pem ec2-user@YOUR_PUBLIC_IP

# Watch the bootstrap log:
sudo tail -f /var/log/portfolio-bootstrap.log
```

Wait until you see:
```
=== Bootstrap complete ===
```

Then exit SSH: `exit`

> **Can't SSH?** Your home IP may have changed since you ran terraform. Run `curl ifconfig.me` and compare to `your_ip_cidr` in your tfvars. If different, update it and run `terraform apply` again.

### Push your code to trigger the pipeline

```bash
# From the repo root (not the terraform/ directory):
cd ..   # if you're in terraform/

git add .
git commit -m "feat: initial portfolio deploy"
git push origin main
```

### Watch the pipeline

Go to your GitHub repo → **Actions** tab. You'll see a workflow run starting. It runs through:

1. **Security** — Terraform static analysis + dependency vulnerability scan
2. **Build** — Builds 3 Docker images (portfolio, AI chat, Bedrock) and pushes to ECR
3. **Deploy** — SSM sends a command to your EC2 to pull and restart the containers
4. **Verify** — Health checks hit your live site endpoints
5. **DAST** — Dynamic security scan
6. **Cleanup** — Prunes old Docker images from EC2
7. **Done** — Summary

The full pipeline takes **8-12 minutes** on first run.

> **If a stage fails:** Click on it to see the logs. Common causes are listed in [Troubleshooting](#15-troubleshooting).

---

## 12. Verify Your Site is Live

Once the pipeline succeeds:

```bash
# Quick check — should return HTTP 200:
curl -I https://yourdomain.com

# Check the AI chat endpoint (if you set up the API key):
curl -I https://ai.yourdomain.com/health
```

Or just open `https://yourdomain.com` in your browser.

**Expected result:** Your portfolio site with your content from `index.html`.

> **"SSL certificate error" in browser?** Let's Encrypt cert may still be issuing. Wait 2-3 minutes and refresh. If it persists, SSH in and check: `sudo certbot certificates`

---

## 13. Optional: Add Grafana Monitoring

The [aws-grafana](https://github.com/YOUR_USERNAME/aws-grafana) companion repo adds:
- **Grafana** dashboards — view your metrics and logs in one place
- **Prometheus** — scrapes CPU, memory, disk, network from your EC2
- **Loki** — stores logs from all Docker containers
- **Promtail** — ships logs from this EC2 to Loki automatically

> Grafana runs on a **separate** EC2 instance (~$7.50/mo extra for t3.micro). It's completely optional — this portfolio site runs fine without it.

To set it up, fork `aws-grafana` and follow its own README. Come back here and set `grafana_active = true` in your `terraform.tfvars`, then run `terraform apply` in this repo to open the security group for Prometheus scraping.

---

## 14. Day-to-Day Operations

### Making changes to your site

Just edit files and push — GitHub Actions does everything else:

```bash
# Edit your portfolio:
code website/index.html

# Commit and push:
git add website/index.html
git commit -m "feat: update skills section"
git push origin main
# Pipeline runs automatically (~8-10 min to deploy)
```

### Making infrastructure changes

Edit Terraform files then apply:

```bash
cd terraform
terraform plan   # preview changes
terraform apply  # apply changes
```

### If your home IP changes (SSH stops working)

```bash
# Get your new IP:
curl ifconfig.me

# Edit terraform.tfvars:
nano terraform/terraform.tfvars
# Update: your_ip_cidr = "NEW.IP.HERE/32"

# Apply the security group change (fast — ~30 seconds):
cd terraform
terraform apply
```

### Destroy and recreate EC2 (to reset to a clean state)

Safe to do — ECR images, Route53 records, and IAM roles are preserved:

```bash
cd terraform

# Destroy ONLY the EC2 and its Elastic IP:
terraform destroy \
  -target=aws_eip.portfolio \
  -target=aws_instance.portfolio

# Recreate:
terraform apply
```

Then wait for bootstrap (~5-10 min) and push to redeploy.

### Check what's running on your server

```bash
# SSH in:
ssh -i ~/.ssh/portfolio-key.pem ec2-user@$(aws ssm get-parameter \
  --name "/YOUR_SSM_NAMESPACE/portfolio/eip" \
  --query "Parameter.Value" --output text)

# See running containers:
docker ps

# View logs:
docker logs portfolio --tail=50
docker logs rerkt-ai --tail=50
docker logs bedrock-ai --tail=50

# Check SSL cert:
sudo certbot certificates
```

> Replace `YOUR_SSM_NAMESPACE` with the value of `ssm_namespace` in your tfvars.

### Rotate the Anthropic API key

```bash
# Update SSM directly (no redeploy of infrastructure needed):
aws ssm put-parameter \
  --name "/YOUR_SSM_NAMESPACE/anthropic-api-key" \
  --value "sk-ant-NEW-KEY-HERE" \
  --type SecureString \
  --overwrite

# Trigger a redeploy so the container picks up the new key:
git commit --allow-empty -m "chore: rotate api key" && git push
```

### Temporarily shut down to stop costs

```bash
cd terraform

# Stop EC2 (Elastic IP is still billed at ~$3.60/mo when instance is stopped):
terraform destroy \
  -target=aws_instance.portfolio

# Or destroy everything (preserves ECR repos, which have prevent_destroy = true):
terraform destroy
```

To bring it back:
```bash
terraform apply
# Wait for bootstrap, then push to deploy
```

---

## 15. Troubleshooting

### Site not loading in browser

**Check 1 — Is the EC2 running?**
```bash
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=portfolio-ec2" \
  --query "Reservations[].Instances[].State.Name" \
  --output text
```
Should say `running`.

**Check 2 — Did bootstrap complete?**
```bash
ssh -i ~/.ssh/portfolio-key.pem ec2-user@YOUR_IP
sudo tail -100 /var/log/portfolio-bootstrap.log
```
Look for `=== Bootstrap complete ===`. If it's not there, bootstrap is still running or failed.

**Check 3 — Are containers running?**
```bash
docker ps
```
Should show `portfolio`, `rerkt-ai`, `bedrock-ai` as `Up`.

**Check 4 — Is the cert issued?**
```bash
sudo certbot certificates
```
Should show your domain with an expiry date.

---

### Can't SSH (connection timed out)

Your home IP changed. Fix it:
```bash
curl ifconfig.me  # get current IP
nano terraform/terraform.tfvars  # update your_ip_cidr
cd terraform && terraform apply
```

---

### GitHub Actions failing — "Error assuming role"

The OIDC trust policy in `oidc.tf` only trusts your specific GitHub repo and the `main` branch. Check:

1. Is `github_org` in your tfvars your **exact** GitHub username? (case-sensitive)
2. Is `github_repo` the **exact** repo name?
3. Are you pushing to `main` branch?
4. Is `AWS_OIDC_ROLE_ARN` secret set correctly in GitHub?

Run `terraform output oidc_role_arn` and compare to what's in the GitHub secret.

---

### GitHub Actions failing — "ECR repo not found"

```bash
cd terraform && terraform apply
```

ECR repos might not have been created. `terraform apply` is idempotent — safe to re-run.

---

### Bootstrap failed (SSL certificate error in log)

Let's Encrypt requires your domain to point to your EC2's public IP **before** the cert is requested. Check:

1. Did Terraform fully complete? Run `terraform output public_ip` to get the IP.
2. Does your domain resolve to that IP?
   ```bash
   dig +short yourdomain.com
   ```
   Should return your EC2's public IP. If it returns nothing or a different IP, Route53 DNS records may not have propagated yet (takes up to 48h, usually <5 min).
3. If DNS is correct but cert failed, SSH in and re-run Certbot manually:
   ```bash
   ssh -i ~/.ssh/portfolio-key.pem ec2-user@YOUR_IP
   # portfolio container must be running (serves the ACME challenge on port 80)
   sudo certbot certonly \
     --webroot -w /var/www/certbot \
     --non-interactive --agree-tos \
     --email you@example.com \
     -d yourdomain.com \
     -d www.yourdomain.com \
     -d ai.yourdomain.com \
     -d bedrock.yourdomain.com
   docker exec portfolio nginx -s reload
   ```

---

### Terraform state error after destroy/recreate

If Terraform gets confused about existing resources:
```bash
cd terraform
terraform refresh   # re-reads real AWS state into tfstate
terraform plan      # verify the plan looks correct
terraform apply
```

---

### "Error: Provided key_pair_name does not exist"

The key pair name in your tfvars must exactly match a key pair in EC2 → Key Pairs in your AWS region. Check spelling and region.

---

## Architecture Reference

```
You push to GitHub main
        │
        ▼
GitHub Actions (OIDC — no static AWS keys)
        │
        ├── Stage 1: Security scans (Trivy, Checkov, npm audit)
        ├── Stage 2: Build 3 Docker images → push to ECR
        ├── Stage 3: SSM send-command → EC2 pulls images + restarts
        ├── Stage 4: Health checks (HTTP 200 on /health)
        ├── Stage 5: DAST scan
        ├── Stage 6: Docker image cleanup on EC2
        └── Stage 7: Pipeline summary

EC2 (t3.nano) runs:
  ├── portfolio     → nginx:443 HTTPS (yourdomain.com)
  ├── rerkt-ai      → Node.js:3001 AI chat proxy (ai.yourdomain.com)
  ├── bedrock-ai    → Node.js:3002 Bedrock AI proxy (bedrock.yourdomain.com)
  └── node-exporter → :9100 host metrics (Prometheus scrape target)

Route53 A records → Elastic IP (static, survives EC2 recreate)
ECR → stores Docker images (3 repos, last 5 tags kept)
SSM Parameter Store → /your-namespace/portfolio/eip + instance-id
AWS Secrets Manager → /your-namespace/anthropic-api-key (encrypted)
```

---

## GitHub Secrets & Variables Reference

**Secrets** (Settings → Secrets and variables → Actions → Secrets tab):

| Secret | Where to get it | Required? |
|--------|----------------|-----------|
| `AWS_OIDC_ROLE_ARN` | `terraform output oidc_role_arn` | Yes |

**Variables** (Settings → Secrets and variables → Actions → Variables tab):

| Variable | Value | Required? |
|----------|-------|-----------|
| `SSM_NAMESPACE` | Must match `ssm_namespace` in tfvars (e.g. `myproject`) | Yes |
| `DOMAIN_NAME` | Your root domain (e.g. `yourdomain.com`) | Yes |
| `AI_IMAGE_NAME` | Must match `ai_image_name` in tfvars (e.g. `chat-ai`) | Yes |

Everything else (instance ID, IP, API key) is read from SSM Parameter Store at runtime automatically.

---

## File Reference

| File | What to edit |
|------|-------------|
| `website/index.html` | Your portfolio content (replace `YOUR_*` placeholders) |
| `terraform/terraform.tfvars` | Your infrastructure config (domain, IP, key pair, etc.) |
| `chat/` | AI chat proxy (Node.js) — optional customization |
| `bedrock/` | Bedrock AI proxy (Node.js) — optional customization |
| `nginx-ssl.conf` | nginx routing config — edit if adding new subdomains |
| `Dockerfile` | Docker image config — rarely needs changing |
