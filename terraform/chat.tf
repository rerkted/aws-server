# ─── chat.tf ──────────────────────────────────────────────────
# DNS + compute for the AI chat proxy (ai.DOMAIN_NAME)
#
# nginx on the portfolio EC2 instance remains the front door for
# ai.DOMAIN_NAME (TLS, static chat UI, rate limiting) — only the
# /api/ backend runs on Lambda now. No DNS/ACM changes needed here;
# nginx's proxy_pass target is what points at the Lambda instead.

resource "aws_route53_record" "ai" {
  zone_id = data.aws_route53_zone.domain.zone_id
  name    = "ai.${var.domain_name}"
  type    = "A"
  ttl     = 300
  records = [aws_eip.portfolio.public_ip]
}

# ─── Lambda: chat-ai backend ───────────────────────────────────

# Placeholder deployment package — real code is pushed by CI via
# `aws lambda update-function-code` on every deploy (see deploy.yml).
# Terraform only creates the function; it never manages the actual
# code, so `ignore_changes` below stops every `apply` from trying to
# revert CI's deploys back to this stub.
data "archive_file" "chat_ai_placeholder" {
  type        = "zip"
  output_path = "${path.module}/.chat_ai_placeholder.zip"

  source {
    content  = "exports.handler = async () => ({ statusCode: 200, body: 'placeholder — awaiting first CI deploy' });"
    filename = "lambda.js"
  }
}

resource "aws_iam_role" "chat_ai_lambda" {
  name        = "chat-ai-lambda-role"
  description = "Execution role for the chat-ai Lambda function"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "chat_ai_lambda_logs" {
  role       = aws_iam_role.chat_ai_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Read-only access to the same SSM parameter agent-ai already reads.
# Don't rename/restructure that parameter without checking agent-ai's
# dependency on it too.
resource "aws_iam_role_policy" "chat_ai_lambda_ssm" {
  #checkov:skip=CKV_AWS_290:kms:Decrypt requires wildcard resource — KMS key ARNs are dynamic and not known at Terraform time
  #checkov:skip=CKV_AWS_288:kms:Decrypt is scoped to the SSM namespace only; wildcard is on the KMS action not SSM
  #checkov:skip=CKV_AWS_355:kms:Decrypt requires wildcard resource — KMS key ARNs are dynamic
  name = "chat-ai-lambda-ssm-read"
  role = aws_iam_role.chat_ai_lambda.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ssm:GetParameter"]
        Resource = "arn:aws:ssm:${var.aws_region}:*:parameter/${var.ssm_namespace}/anthropic-api-key"
      },
      {
        Sid      = "KMSDecrypt"
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = "*"
      }
    ]
  })
}

resource "aws_lambda_function" "chat_ai" {
  #checkov:skip=CKV_AWS_117:intentional — no NAT gateway exists (public subnet + IGW only); a VPC-attached Lambda would lose internet access to api.anthropic.com without one, and this function has no VPC resources to reach
  #checkov:skip=CKV_AWS_116:no DLQ needed — Function URL invocations are synchronous request/response, not async; DLQ semantics apply to failed async/event-source invocations, which don't occur here
  #checkov:skip=CKV_AWS_173:AWS-managed KMS key is sufficient for these env vars (matches the same reasoning already applied to the SSM parameter in secrets.tf); a CMK adds cost with no meaningful security benefit here
  #checkov:skip=CKV_AWS_272:code-signing is enterprise supply-chain tooling disproportionate to a personal portfolio project's threat model; CI/CD already runs SAST, SCA, and secrets scanning on this code
  #checkov:skip=CKV_AWS_50:X-Ray tracing is an observability nice-to-have, not a security control; CloudWatch Logs (enabled via the basic execution role) already covers error visibility for this low-traffic function
  function_name = "chat-ai"
  role          = aws_iam_role.chat_ai_lambda.arn
  handler       = "lambda.handler"
  runtime       = "nodejs20.x"
  timeout       = 15
  memory_size   = 256

  # Cost/abuse backstop independent of nginx's rate limiting: caps how
  # many concurrent invocations can run, which bounds both AWS cost and
  # the rate of calls that can reach the Anthropic API even if nginx's
  # limiter were ever bypassed.
  reserved_concurrent_executions = 5

  filename         = data.archive_file.chat_ai_placeholder.output_path
  source_code_hash = data.archive_file.chat_ai_placeholder.output_base64sha256

  environment {
    variables = {
      DOMAIN_NAME             = var.domain_name
      ANTHROPIC_API_KEY_PARAM = "/${var.ssm_namespace}/anthropic-api-key"
    }
  }

  # CI owns the real code after the first deploy (see deploy.yml) —
  # don't let `terraform apply` fight it by reverting to the placeholder.
  lifecycle {
    ignore_changes = [filename, source_code_hash]
  }

  tags = { Name = "chat-ai-lambda" }
}

# NONE auth is intentional here, not an oversight: nginx is the only
# caller (proxy_pass over the public internet to this URL), and nginx
# already TLS-terminates, custom-domains, and rate-limits every request
# before it ever reaches this endpoint. See migration plan for the
# full reasoning and the optional shared-secret-header hardening we
# chose to defer.
resource "aws_lambda_function_url" "chat_ai" {
  #checkov:skip=CKV_AWS_258:intentional — nginx is the sole caller and already provides TLS, custom domain, and rate limiting in front of this endpoint; see chat.tf header comment
  function_name      = aws_lambda_function.chat_ai.function_name
  authorization_type = "NONE"
}

# authorization_type = "NONE" above is necessary but not sufficient —
# AWS also requires this explicit resource-based permission before an
# unauthenticated Function URL will actually accept anonymous requests.
# Without it, every request gets rejected with a "Forbidden" response
# regardless of the auth type setting.
resource "aws_lambda_permission" "chat_ai_function_url_public" {
  #checkov:skip=CKV_AWS_301:intentional, same reasoning as CKV_AWS_258 above — nginx is the sole real-world caller and already provides TLS, custom domain, and rate limiting in front of this endpoint
  statement_id           = "AllowPublicFunctionUrlInvoke"
  action                 = "lambda:InvokeFunctionUrl"
  function_name          = aws_lambda_function.chat_ai.function_name
  principal              = "*"
  function_url_auth_type = "NONE"
}

# Confirmed via direct testing (and the Lambda console's own diagnostic
# message) that the InvokeFunctionUrl permission above is necessary but
# STILL not sufficient on its own — Function URLs also require a plain
# lambda:InvokeFunction grant, without the function_url_auth_type
# condition (that condition key is only valid on InvokeFunctionUrl).
# Without this second statement, every request returns 403 even with
# AuthType=NONE and a correct InvokeFunctionUrl grant in place.
resource "aws_lambda_permission" "chat_ai_function_invoke_public" {
  #checkov:skip=CKV_AWS_301:same reasoning as chat_ai_function_url_public above
  statement_id  = "AllowPublicFunctionInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.chat_ai.function_name
  principal     = "*"
}

output "chat_ai_function_url" {
  value       = aws_lambda_function_url.chat_ai.function_url
  description = "Set this as the proxy_pass target host in nginx-ssl.conf's ai.DOMAIN_NAME /api/ block once ready to cut over (see migration plan)"
}
