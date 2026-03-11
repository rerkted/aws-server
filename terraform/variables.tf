# ─── variables.tf ─────────────────────────────────────────────

variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "production"
}

variable "instance_type" {
  description = "EC2 instance type. t3.nano ~$3.50/mo, t3.micro ~$7.50/mo"
  type        = string
  default     = "t3.nano"
}

variable "key_pair_name" {
  description = "Name of existing EC2 key pair for SSH access"
  type        = string
}

variable "your_ip_cidr" {
  description = "Your home/office IP in CIDR notation for SSH access e.g. 1.2.3.4/32"
  type        = string
  sensitive   = true
}

variable "domain_name" {
  description = "Your domain name"
  type        = string
  default     = "rerktserver.com"
}

variable "admin_email" {
  description = "Email for Let's Encrypt cert expiry notifications"
  type        = string
}

variable "github_org" {
  description = "GitHub username or organization that owns the repo"
  type        = string
  default     = "rerkted"
}

variable "github_repo" {
  description = "GitHub repository name"
  type        = string
  default     = "aws-server"
}

variable "grafana_active" {
  description = "Set to false when grafana stack is destroyed — disables SSM lookup of grafana EIP"
  type        = bool
  default     = true
}

variable "anthropic_api_key" {
  description = "Anthropic API key — stored in AWS Secrets Manager, never in GitHub secrets"
  type        = string
  sensitive   = true
}
