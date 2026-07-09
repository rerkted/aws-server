# ─── ecr.tf ───────────────────────────────────────────────────
# ECR repository for Docker golden images

resource "aws_ecr_repository" "portfolio" {
  #checkov:skip=CKV_AWS_51:MUTABLE tags required — CI/CD pipeline uses the `latest` tag for rolling deployments
  #checkov:skip=CKV_AWS_136:AWS-managed encryption is sufficient for this ECR use case
  #checkov:skip=CKV_AWS_337:AWS-managed KMS key is sufficient; CMK adds cost with no security benefit here
  name                 = "portfolio"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true  # Free vulnerability scanning on every push
  }

  lifecycle {
    prevent_destroy = true  # Never accidentally delete the image registry
  }

  tags = { Name = "portfolio-ecr" }
}

# Keep only the last 5 images to minimize storage costs
resource "aws_ecr_lifecycle_policy" "portfolio" {
  repository = aws_ecr_repository.portfolio.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep only last 5 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 5
      }
      action = { type = "expire" }
    }]
  })
}

# ─── ECR repo for AI chat proxy ───────────────────────────────
resource "aws_ecr_repository" "rerkt_ai" {
  #checkov:skip=CKV_AWS_51:MUTABLE tags required — CI/CD pipeline uses the `latest` tag for rolling deployments
  #checkov:skip=CKV_AWS_136:AWS-managed encryption is sufficient for this ECR use case
  #checkov:skip=CKV_AWS_337:AWS-managed KMS key is sufficient; CMK adds cost with no security benefit here
  name                 = var.ai_image_name
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  lifecycle {
    prevent_destroy = true
  }

  tags = { Name = "${var.ai_image_name}-ecr" }
}

resource "aws_ecr_lifecycle_policy" "rerkt_ai" {
  repository = aws_ecr_repository.rerkt_ai.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep only last 5 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 5
      }
      action = { type = "expire" }
    }]
  })
}

# ─── ECR repo for Bedrock AI proxy ────────────────────────────
resource "aws_ecr_repository" "bedrock_ai" {
  #checkov:skip=CKV_AWS_51:MUTABLE tags required — CI/CD pipeline uses the `latest` tag for rolling deployments
  #checkov:skip=CKV_AWS_136:AWS-managed encryption is sufficient for this ECR use case
  #checkov:skip=CKV_AWS_337:AWS-managed KMS key is sufficient; CMK adds cost with no security benefit here
  name                 = "bedrock-ai"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  lifecycle {
    prevent_destroy = true
  }

  tags = { Name = "bedrock-ai-ecr" }
}

resource "aws_ecr_lifecycle_policy" "bedrock_ai" {
  repository = aws_ecr_repository.bedrock_ai.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep only last 5 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 5
      }
      action = { type = "expire" }
    }]
  })
}

# ─── ECR repo for Infrastructure AI Agent ─────────────────────
resource "aws_ecr_repository" "agent_ai" {
  #checkov:skip=CKV_AWS_51:MUTABLE tags required — CI/CD pipeline uses the `latest` tag for rolling deployments
  #checkov:skip=CKV_AWS_136:AWS-managed encryption is sufficient for this ECR use case
  #checkov:skip=CKV_AWS_337:AWS-managed KMS key is sufficient; CMK adds cost with no security benefit here
  name                 = "agent-ai"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  lifecycle {
    prevent_destroy = true
  }

  tags = { Name = "agent-ai-ecr" }
}

resource "aws_ecr_lifecycle_policy" "agent_ai" {
  repository = aws_ecr_repository.agent_ai.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep only last 5 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 5
      }
      action = { type = "expire" }
    }]
  })
}
