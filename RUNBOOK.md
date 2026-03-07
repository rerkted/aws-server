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

```bash
sudo systemctl status promtail
sudo journalctl -u promtail -n 30 --no-pager
```

If Promtail is down:
```bash
sudo systemctl restart promtail
```

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

## GitHub Secrets Required

| Secret | Description |
|--------|-------------|
| `AWS_OIDC_ROLE_ARN` | GitHub Actions OIDC role ARN |
| `ANTHROPIC_API_KEY` | Anthropic API key for rerkt-ai |

Instance IDs and IPs are read from SSM automatically — no secrets needed for those.

---

## Deployment Order (First-Time Setup)

Deploy aws-server before aws-grafana — aws-grafana reads the portfolio EIP from SSM for its security group:

1. `terraform apply` in aws-server
2. `terraform apply` in aws-grafana
3. Push aws-grafana to deploy the stack
