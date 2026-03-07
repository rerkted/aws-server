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

echo "Docker and certbot installed at $(date)"

# ── 2. ECR login ──────────────────────────────────────────────
aws ecr get-login-password --region "$AWS_REGION" | \
  docker login --username AWS --password-stdin "$ECR_REGISTRY"

echo "ECR login successful"

# ── 3. Create webroot for certbot challenge ───────────────────
mkdir -p /var/www/certbot

# ── 4. Start HTTP-only container (no SSL certs needed yet) ────
docker run -d \
  --name portfolio \
  --restart unless-stopped \
  -p 80:80 \
  -v /var/www/certbot:/var/www/certbot \
  "$ECR_REGISTRY:latest"

echo "Waiting for nginx to be ready..."
for attempt in $(seq 1 30); do
  if curl -s http://localhost/health | grep -q "OK"; then
    echo "nginx is ready after attempt $attempt"
    break
  fi
  echo "Waiting... attempt $attempt"
  sleep 5
done

# ── 5. Issue SSL certificate ──────────────────────────────────
echo "Requesting SSL cert at $(date)"
certbot certonly \
  --webroot \
  --webroot-path /var/www/certbot \
  --non-interactive \
  --agree-tos \
  --email "$EMAIL" \
  -d "$DOMAIN" \
  -d "www.$DOMAIN"

echo "SSL cert issued successfully at $(date)"

# ── 6. Restart container with SSL config and certs mounted ────
docker stop portfolio && docker rm portfolio

docker run -d \
  --name portfolio \
  --restart always \
  -p 80:80 \
  -p 443:443 \
  -v /etc/letsencrypt:/etc/letsencrypt:ro \
  -v /var/www/certbot:/var/www/certbot \
  "$ECR_REGISTRY:latest" \
  nginx -c /etc/nginx/nginx-ssl.conf -g "daemon off;"

echo "Container restarted with HTTPS at $(date)"

# ── 7. Auto-renewal cron (runs twice daily) ───────────────────
mkdir -p /etc/cron.d

cat > /etc/cron.d/certbot-renew << 'CRON'
0 3,15 * * * root certbot renew --quiet --deploy-hook "docker kill -s HUP portfolio" 2>&1 | logger -t certbot
CRON
chmod 644 /etc/cron.d/certbot-renew

# ── 8. ECR token refresh (expires every 12hrs) ────────────────
cat > /etc/cron.d/ecr-login << CRON
0 */11 * * * root aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin $ECR_REGISTRY 2>&1 | logger -t ecr-login
CRON
chmod 644 /etc/cron.d/ecr-login

# ── 9. Install Promtail for log shipping to Grafana Loki ─────
# Read Grafana EIP from SSM Parameter Store (set by aws-grafana terraform)
GRAFANA_EIP=$(aws ssm get-parameter \
  --region "${aws_region}" \
  --name "/rerktserver/grafana/eip" \
  --query "Parameter.Value" \
  --output text)
LOKI_URL="http://$${GRAFANA_EIP}:3100/loki/api/v1/push"

PROMTAIL_VERSION="2.9.0"
curl -fsSL "https://github.com/grafana/loki/releases/download/v$${PROMTAIL_VERSION}/promtail-linux-amd64.zip" \
  -o /tmp/promtail.zip
unzip -o /tmp/promtail.zip -d /tmp
mv /tmp/promtail-linux-amd64 /usr/local/bin/promtail
chmod +x /usr/local/bin/promtail
rm /tmp/promtail.zip

cat > /etc/promtail-config.yml << PROMTAIL_CONF
server:
  http_listen_port: 9080
  grpc_listen_port: 0

positions:
  filename: /var/lib/promtail/positions.yaml

clients:
  - url: $LOKI_URL

scrape_configs:
  # Docker container logs — portfolio, rerkt-ai, bedrock-ai
  - job_name: portfolio-containers
    docker_sd_configs:
      - host: unix:///var/run/docker.sock
        refresh_interval: 5s
    relabel_configs:
      - source_labels: [__meta_docker_container_name]
        regex: /(.*)
        target_label: container
      - source_labels: [__meta_docker_container_image]
        target_label: image
      - source_labels: [container]
        regex: (.+)
        action: keep
    pipeline_stages:
      - docker: {}

  # Auth logs — SSH logins, sudo usage (CSPM)
  - job_name: auth
    static_configs:
      - targets: [localhost]
        labels:
          job: auth
          host: rerktserver.com
          __path__: /var/log/secure

  # System logs (CSPM)
  - job_name: system
    static_configs:
      - targets: [localhost]
        labels:
          job: system
          host: rerktserver.com
          __path__: /var/log/messages
PROMTAIL_CONF

mkdir -p /var/lib/promtail
usermod -aG docker root

cat > /etc/systemd/system/promtail.service << 'SYSTEMD'
[Unit]
Description=Promtail log shipper
After=network.target docker.service
Wants=docker.service

[Service]
ExecStart=/usr/local/bin/promtail -config.file=/etc/promtail-config.yml
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
SYSTEMD

systemctl daemon-reload
systemctl enable promtail
systemctl start promtail

echo "Promtail installed and shipping logs to Loki"

echo "=== Bootstrap complete at $(date) ==="