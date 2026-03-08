# ─── secrets.tf ───────────────────────────────────────────────
# SSM Parameter Store SecureString — stores sensitive credentials
# Free tier (standard parameter), encrypted with AWS managed KMS key
# EC2 fetches at runtime via its IAM role using --with-decryption

resource "aws_ssm_parameter" "anthropic_api_key" {
  name        = "/rerktserver/anthropic-api-key"
  description = "Anthropic API key for rerkt-ai container"
  type        = "SecureString"
  value       = var.anthropic_api_key

  tags = { Name = "anthropic-api-key" }
}
