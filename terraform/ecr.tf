# ─── ecr.tf ───────────────────────────────────────────────────
# ECR repository for Docker golden images

resource "aws_ecr_repository" "portfolio" {
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

# ─── ECR repo for Rerkt.AI proxy ──────────────────────────────
resource "aws_ecr_repository" "rerkt_ai" {
  name                 = "rerkt-ai"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  lifecycle {
    prevent_destroy = true
  }

  tags = { Name = "rerkt-ai-ecr" }
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
