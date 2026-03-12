# ─── main.tf ──────────────────────────────────────────────────
# Provider configuration and data sources

terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Remote state (uncomment after creating S3 bucket manually once)
  # backend "s3" {
  #   bucket = "your-name-tf-state"
  #   key    = "portfolio/terraform.tfstate"
  #   region = "us-east-1"
  # }
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      Project     = "portfolio"
      ManagedBy   = "terraform"
      Environment = var.environment
    }
  }
}

## ─── DATA SOURCES ─────────────────────────────────────────────

data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

data "aws_availability_zones" "available" {}

# Grafana EIP — used to restrict Prometheus scrape ports to Grafana server only
# Only read when grafana stack is active (set grafana_active=false in tfvars when destroyed)
data "aws_ssm_parameter" "grafana_eip" {
  count = var.grafana_active ? 1 : 0
  name  = "/${var.ssm_namespace}/grafana/eip"
}
