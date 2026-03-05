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
yum install -y docker python3-pip augeas-libs

# Install certbot using pip3 (works on Amazon Linux 2023)
pip3 install certbot requests

systemctl enable docker
systemctl start docker

echo "Docker and certbot installed at $(date)"

# ── 2. ECR login ──────────────────────────────────────────────
aws ecr get-login-password --region "$AWS_REGION" | \
  docker login --username AWS --password-stdin "$ECR_REGISTRY"

echo "ECR login successful"

# ── 3. Create webroot for certbot challenge ───────────────────
mkdir -p /var/www/certbot

# ── 4. Start HTTP-only container for ACME challenge ──────────
docker run -d \
  --name portfolio \
  --restart unless-stopped \
  -p 80:80 \
  -v /var/www/certbot:/var/www/certbot \
  "$ECR_REGISTRY:latest"

echo "Waiting 15s for nginx to be ready..."
sleep 15

# Verify container is running before requesting cert
if ! docker ps | grep -q portfolio; then
  echo "ERROR: portfolio container failed to start"
  docker logs portfolio
  exit 1
fi

echo "Container running, requesting SSL cert..."

# ── 5. Issue SSL certificate ──────────────────────────────────
certbot certonly \
  --webroot \
  --webroot-path /var/www/certbot \
  --non-interactive \
  --agree-tos \
  --email "$EMAIL" \
  -d "$DOMAIN" \
  -d "www.$DOMAIN"

echo "SSL cert issued successfully"

# ── 6. Restart container with SSL certs mounted ───────────────
docker stop portfolio && docker rm portfolio

docker run -d \
  --name portfolio \
  --restart always \
  -p 80:80 \
  -p 443:443 \
  -v /etc/letsencrypt:/etc/letsencrypt:ro \
  -v /var/www/certbot:/var/www/certbot \
  "$ECR_REGISTRY:latest"

echo "Container restarted with HTTPS at $(date)"

# ── 7. Auto-renewal cron ──────────────────────────────────────
cat > /etc/cron.d/certbot-renew << 'CRON'
0 3,15 * * * root certbot renew --quiet --deploy-hook "docker kill -s HUP portfolio" 2>&1 | logger -t certbot
CRON
chmod 644 /etc/cron.d/certbot-renew

# ── 8. ECR token refresh cron ─────────────────────────────────
cat > /etc/cron.d/ecr-login << CRON
0 */11 * * * root aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin $ECR_REGISTRY 2>&1 | logger -t ecr-login
CRON
chmod 644 /etc/cron.d/ecr-login

echo "=== Bootstrap complete at $(date) ==="