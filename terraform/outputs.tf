# ─── outputs.tf ───────────────────────────────────────────────
# All Terraform outputs

output "public_ip" {
  value       = aws_eip.portfolio.public_ip
  description = "Portfolio public IP — update GitHub secret EC2_PUBLIC_IP with this"
}

output "instance_id" {
  value       = aws_instance.portfolio.id
  description = "EC2 instance ID — update GitHub secret EC2_INSTANCE_ID with this"
}

output "ecr_repository_url" {
  value       = aws_ecr_repository.portfolio.repository_url
  description = "ECR URL for pushing Docker images"
}

output "site_url" {
  value       = "https://${var.domain_name}"
  description = "Your live site URL"
}
