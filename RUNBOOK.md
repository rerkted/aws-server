# Portfolio EC2 Runbook

## Normal Deploy

Push to main — GitHub Actions handles everything automatically:

```bash
git push origin main
```

Pipeline: build images → Trivy scan → push to ECR → SSM deploy to EC2.

---

## Destroy and Recreate EC2

```bash
# 1. Destroy and recreate
cd aws-server/terraform
terraform destroy
terraform apply
# Automatically stores new EIP + instance ID in SSM — no manual steps
```

```bash
# 2. Check your home IP hasn't changed
curl ifconfig.me
# Compare to your_ip_cidr in terraform.tfvars
# If different, update terraform.tfvars and re-run terraform apply
```

```bash
# 3. Wait for bootstrap to complete (~5-8 min)
ssh -i ~/.ssh/portfolio-key.pem ec2-user@$(aws ssm get-parameter \
  --name "/rerktserver/portfolio/eip" --query "Parameter.Value" --output text)

sudo tail -f /var/log/portfolio-bootstrap.log
# Wait for: "=== Bootstrap complete ==="
# Then exit SSH
```

```bash
# 4. Push to trigger deploy
git push origin main
# Or trigger manually from GitHub Actions → Run workflow
```

```bash
# 5. Verify
# https://rerktserver.com
# https://ai.rerktserver.com
# https://bedrock.rerktserver.com
```

---

## IP Whitelist Changed

If your home IP changes, SSH will time out. Fix:

```bash
# Get your current IP
curl ifconfig.me

# Update terraform.tfvars
vi aws-server/terraform/terraform.tfvars
# Change your_ip_cidr to <your-ip>/32

# Apply the security group change
cd aws-server/terraform
terraform apply
```

---

## Check Container Status on EC2

```bash
ssh -i ~/.ssh/portfolio-key.pem ec2-user@$(aws ssm get-parameter \
  --name "/rerktserver/portfolio/eip" --query "Parameter.Value" --output text)

docker ps
docker logs portfolio --tail=50
docker logs rerkt-ai --tail=50
docker logs bedrock-ai --tail=50
```

---

## Check Promtail (Log Shipping)

Promtail is managed automatically by the `sync-loki-url.timer` (runs every 5 min):
- **Grafana up** → promtail starts automatically and ships logs to Loki
- **Grafana destroyed** → promtail stops automatically (SSM param deleted)

```bash
# Check status
sudo systemctl status promtail
sudo journalctl -u promtail -n 30 --no-pager

# Check sync timer logs
sudo journalctl -t sync-loki-url -n 20 --no-pager
```

> Do not manually restart promtail when grafana is down — the sync timer will start it automatically once grafana is back up.

---

## SSL Certificate

```bash
# View cert expiry
sudo certbot certificates

# Test renewal
sudo certbot renew --dry-run

# Force renewal
sudo certbot renew --force-renewal
sudo docker kill -s HUP portfolio
```

---

## ECR Login (if pulling manually)

```bash
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin \
  $(aws ssm get-parameter --name "/rerktserver/portfolio/eip" \
    --query "Parameter.Value" --output text)
```

---

## Useful Commands

```bash
# Get current portfolio EIP
aws ssm get-parameter --name "/rerktserver/portfolio/eip" \
  --query "Parameter.Value" --output text

# Get current instance ID
aws ssm get-parameter --name "/rerktserver/portfolio/instance-id" \
  --query "Parameter.Value" --output text

# Check instance state
aws ec2 describe-instances \
  --instance-ids $(aws ssm get-parameter --name "/rerktserver/portfolio/instance-id" \
    --query "Parameter.Value" --output text) \
  --query "Reservations[0].Instances[0].State.Name" --output text

# SSH into portfolio EC2
ssh -i ~/.ssh/portfolio-key.pem ec2-user@$(aws ssm get-parameter \
  --name "/rerktserver/portfolio/eip" --query "Parameter.Value" --output text)

# Watch bootstrap log
sudo tail -f /var/log/portfolio-bootstrap.log
```

---

## Rotate Anthropic API Key

1. Get a new key from [console.anthropic.com](https://console.anthropic.com)
2. Update SSM:

```bash
aws ssm put-parameter \
  --name "/rerktserver/anthropic-api-key" \
  --value "sk-ant-NEW-KEY-HERE" \
  --type SecureString \
  --overwrite
```

3. Redeploy so the container restarts with the new key:

```bash
git commit --allow-empty -m "chore: rotate anthropic api key" && git push
```

---

## GitHub Secrets Required

| Secret | Description |
|--------|-------------|
| `AWS_OIDC_ROLE_ARN` | GitHub Actions OIDC role ARN |

All other credentials (Anthropic API key, instance IDs, IPs) are read from SSM automatically.

---

## Deployment Order (First-Time Setup)

Deploy aws-server before aws-grafana — aws-grafana reads the portfolio EIP from SSM for its security group:

1. `terraform apply` in aws-server
2. `terraform apply` in aws-grafana
3. Push aws-grafana to deploy the stack

---

## Re-enabling Grafana Monitoring

When spinning grafana back up after a destroy, uncomment the following in aws-server:

**`terraform/userdata.sh`** — re-enable cAdvisor (if on t3.micro or larger):
```
# Uncomment the cAdvisor docker run block
```

**`terraform/security.tf`** — re-enable cAdvisor port 8080 ingress rule:
```
# Uncomment the port 8080 ingress block
```

**`.github/workflows/deploy.yml`** — uncomment node-exporter ensure-running line if needed.

Once grafana terraform is applied and deployed, the `sync-loki-url.timer` on aws-server will detect the new grafana EIP in SSM and **automatically start promtail** within 5 minutes — no manual action needed.
