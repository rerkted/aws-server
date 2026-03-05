#!/bin/bash
set -euo pipefail

ECR_REGISTRY="${ecr_registry}"
AWS_REGION="${aws_region}"
DOMAIN="${domain_name}"
EMAIL="${admin_email}"

LOG=/var/log/portfolio-bootstrap.log
exec >> "$LOG" 2>&1
echo "=== Bootstrap started at $(date) ==="

# ── 1. Install dependencies ───────────────────────────────────
yum update -y
yum install -y docker python3-pip
pip3 install certbot

systemctl enable docker
systemctl start docker

# ── 2. ECR login ──────────────────────────────────────────────
aws ecr get-login-password --region "$AWS_REGION" | \
  docker login --username AWS --password-stdin "$ECR_REGISTRY"

# ── 3. Start HTTP-only first (no SSL yet) ─────────────────────
mkdir -p /var/www/certbot

docker run -d \
  --name portfolio \
  --restart always \
  -p 80:80 \
  -p 443:443 \
  -v /var/www/certbot:/var/www/certbot \
  -e SSL_ENABLED=false \
  "$ECR_REGISTRY:latest"

echo "Container started on HTTP, waiting 10s before cert request..."
sleep 10

# ── 4. Issue SSL cert ─────────────────────────────────────────
certbot certonly \
  --webroot \
  --webroot-path /var/www/certbot \
  --non-interactive \
  --agree-tos \
  --email "$EMAIL" \
  -d "$DOMAIN" \
  -d "www.$DOMAIN"

echo "SSL cert issued for $DOMAIN"

# ── 5. Restart container with SSL certs mounted ───────────────
docker stop portfolio && docker rm portfolio

docker run -d \
  --name portfolio \
  --restart always \
  -p 80:80 \
  -p 443:443 \
  -v /etc/letsencrypt:/etc/letsencrypt:ro \
  -v /var/www/certbot:/var/www/certbot \
  "$ECR_REGISTRY:latest"

echo "Container restarted with HTTPS"

# ── 6. Auto-renewal cron ──────────────────────────────────────
cat > /etc/cron.d/certbot-renew << 'CRON'
0 3,15 * * * root certbot renew --quiet --deploy-hook "docker kill -s HUP portfolio" 2>&1 | logger -t certbot
CRON
chmod 644 /etc/cron.d/certbot-renew

# ── 7. ECR token refresh ──────────────────────────────────────
cat > /etc/cron.d/ecr-login << CRON
0 */11 * * * root aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin $ECR_REGISTRY 2>&1 | logger -t ecr-login
CRON
chmod 644 /etc/cron.d/ecr-login

echo "=== Bootstrap complete at $(date) ==="