# ─── secrets.tf ───────────────────────────────────────────────
# AWS Secrets Manager — stores sensitive credentials
# The EC2 instance fetches these at runtime via its IAM role
# Never stored in GitHub secrets or SSM plain text

resource "aws_secretsmanager_secret" "anthropic_api_key" {
  name                    = "/rerktserver/anthropic-api-key"
  description             = "Anthropic API key for rerkt-ai container"
  recovery_window_in_days = 0  # Allow immediate deletion for dev environments

  tags = { Name = "anthropic-api-key" }
}

resource "aws_secretsmanager_secret_version" "anthropic_api_key" {
  secret_id     = aws_secretsmanager_secret.anthropic_api_key.id
  secret_string = var.anthropic_api_key
}
