#!/bin/bash
set -euo pipefail

# ─── Bootstrap EC2: Docker + Certbot SSL ───────────────────────
# Runs ONCE on first launch via Terraform user_data

ECR_REGISTRY="${ecr_registry}"
AWS_REGION="${aws_region}"
DOMAIN="${domain_name}"
EMAIL="${admin_email}"

LOG=/var/log/portfolio-bootstrap.log
exec >> "$LOG" 2>&1
echo "=== Bootstrap started at $(date) ==="

# ── 1. Install dependencies ───────────────────────────────────
yum update -y
yum install -y docker python3

pip3 install certbot certbot-nginx

systemctl enable docker
systemctl start docker

# ── 2. ECR login ──────────────────────────────────────────────
aws ecr get-login-password --region "$AWS_REGION" | \
  docker login --username AWS --password-stdin "$ECR_REGISTRY"

# ── 3. Bootstrap: HTTP-only container for ACME challenge ──────
mkdir -p /var/www/certbot
docker run -d \
  --name portfolio-bootstrap \
  -p 80:80 \
  -v /var/www/certbot:/var/www/certbot \
  "$ECR_REGISTRY:latest"

sleep 8

# ── 4. Issue Let's Encrypt cert ───────────────────────────────
certbot certonly \
  --webroot \
  --webroot-path /var/www/certbot \
  --non-interactive \
  --agree-tos \
  --email "$EMAIL" \
  -d "$DOMAIN" \
  -d "www.$DOMAIN"

echo "SSL cert issued for $DOMAIN"

# ── 5. Switch to HTTPS production container ───────────────────
docker stop portfolio-bootstrap && docker rm portfolio-bootstrap

docker run -d \
  --name portfolio \
  --restart always \
  -p 80:80 \
  -p 443:443 \
  -v /etc/letsencrypt:/etc/letsencrypt:ro \
  -v /var/www/certbot:/var/www/certbot \
  "$ECR_REGISTRY:latest"

# ── 6. Auto-renewal cron (runs twice daily, renews if <30 days left) ──
cat > /etc/cron.d/certbot-renew << 'CRON'
0 3,15 * * * root certbot renew --quiet --deploy-hook "docker kill -s HUP portfolio" 2>&1 | logger -t certbot
CRON
chmod 644 /etc/cron.d/certbot-renew

# ── 7. ECR token refresh (expires every 12hrs) ────────────────
cat > /etc/cron.d/ecr-login << CRON
0 */11 * * * root aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin $ECR_REGISTRY 2>&1 | logger -t ecr-login
CRON
chmod 644 /etc/cron.d/ecr-login

echo "=== Bootstrap complete at $(date) ==="
