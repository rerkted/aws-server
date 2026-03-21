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
  -d "www.$DOMAIN" \
  -d "ai.$DOMAIN" \
  -d "bedrock.$DOMAIN" \
  -d "agent.$DOMAIN"

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
# Falls back to placeholder if grafana stack is not yet deployed — sync-loki-url.timer will update it
GRAFANA_EIP=$(aws ssm get-parameter \
  --region "${aws_region}" \
  --name "/${ssm_namespace}/grafana/eip" \
  --query "Parameter.Value" \
  --output text 2>/dev/null || echo "127.0.0.1")
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

  # Auth logs — SSH logins, sudo usage (CSPM) — Amazon Linux 2023 uses journald
  - job_name: auth
    journal:
      matches: _SYSTEMD_UNIT=sshd.service
      labels:
        job: auth
        host: ${domain_name}

  # System logs (CSPM) — Amazon Linux 2023 uses journald
  - job_name: system
    journal:
      labels:
        job: system
        host: ${domain_name}
PROMTAIL_CONF

mkdir -p /var/lib/promtail
usermod -aG docker root

# ── Cron: auto-update promtail Loki URL if grafana EIP changes in SSM ────────
cat > /usr/local/bin/sync-loki-url.sh << 'SYNC'
#!/bin/bash
REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region)
LATEST=$(aws ssm get-parameter --region "$REGION" --name "/${ssm_namespace}/grafana/eip" --query "Parameter.Value" --output text 2>/dev/null)

# Grafana destroyed — stop promtail if running
if [ -z "$LATEST" ]; then
  if systemctl is-active --quiet promtail; then
    systemctl stop promtail
    logger -t sync-loki-url "Grafana EIP not found in SSM — stopping promtail"
  fi
  exit 0
fi

# Grafana available — ensure promtail is running with correct URL
CURRENT=$(grep -oP 'http://\K[^:]+(?=:3100)' /etc/promtail-config.yml)
if [ "$CURRENT" != "$LATEST" ]; then
  sed -i "s|http://$CURRENT:3100|http://$LATEST:3100|g" /etc/promtail-config.yml
  logger -t sync-loki-url "Updated Loki URL from $CURRENT to $LATEST"
fi
if ! systemctl is-active --quiet promtail; then
  systemctl start promtail
  logger -t sync-loki-url "Grafana EIP found — started promtail"
fi
SYNC
chmod +x /usr/local/bin/sync-loki-url.sh

cat > /etc/systemd/system/sync-loki-url.service << 'SVC'
[Unit]
Description=Sync Loki URL from SSM

[Service]
Type=oneshot
ExecStart=/usr/local/bin/sync-loki-url.sh
SVC

cat > /etc/systemd/system/sync-loki-url.timer << 'TMR'
[Unit]
Description=Sync Loki URL every 5 minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
TMR

systemctl daemon-reload
systemctl enable --now sync-loki-url.timer

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

# ── 10. Start infrastructure monitoring exporters ────────────
# Node Exporter — host metrics (CPU, memory, disk, network)
# --network host binds to port 9100; SG restricts to Grafana server only
docker run -d \
  --name node-exporter \
  --restart always \
  --pid host \
  --network host \
  -v /:/host:ro,rslave \
  prom/node-exporter:v1.8.2 \
  --path.rootfs=/host

echo "Node Exporter started"

# ── cAdvisor — per-container metrics (disabled on t3.nano — OOM risk)
# Uncomment if upgraded to t3.micro or larger (requires port 8080 in security.tf)
# docker run -d \
#   --name cadvisor \
#   --restart always \
#   --privileged \
#   -p 8080:8080 \
#   -v /:/rootfs:ro \
#   -v /var/run:/var/run:ro \
#   -v /sys:/sys:ro \
#   -v /var/lib/docker/:/var/lib/docker:ro \
#   -v /dev/disk/:/dev/disk:ro \
#   gcr.io/cadvisor/cadvisor:v0.49.1

# ── 11. SSM agent watchdog (auto-restart if connection lost) ─
cat > /usr/local/bin/ssm-watchdog.sh << 'WATCHDOG'
#!/bin/bash
if ! systemctl is-active --quiet amazon-ssm-agent; then
  logger -t ssm-watchdog "SSM agent not active — restarting"
  systemctl restart amazon-ssm-agent
fi
WATCHDOG
chmod +x /usr/local/bin/ssm-watchdog.sh

cat > /etc/systemd/system/ssm-watchdog.service << 'SVC'
[Unit]
Description=SSM agent watchdog

[Service]
Type=oneshot
ExecStart=/usr/local/bin/ssm-watchdog.sh
SVC

cat > /etc/systemd/system/ssm-watchdog.timer << 'TMR'
[Unit]
Description=Check SSM agent every 5 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
TMR

systemctl daemon-reload
systemctl enable --now ssm-watchdog.timer

echo "SSM agent watchdog installed"

echo "=== Bootstrap complete at $(date) ==="