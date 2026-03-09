# ─── secrets.tf ───────────────────────────────────────────────
# SSM Parameter Store SecureString — stores sensitive credentials
# Free tier (standard parameter), encrypted with AWS managed KMS key
# EC2 fetches at runtime via its IAM role using --with-decryption

resource "aws_ssm_parameter" "anthropic_api_key" {
  #checkov:skip=CKV_AWS_337:AWS-managed KMS key is sufficient for API key storage; CMK adds cost with no security benefit here
  name        = "/rerktserver/anthropic-api-key"
  description = "Anthropic API key for rerkt-ai container"
  type        = "SecureString"
  value       = var.anthropic_api_key

  tags = { Name = "anthropic-api-key" }
}
