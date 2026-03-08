# ─── vpc.tf ───────────────────────────────────────────────────
# VPC, subnet, internet gateway, route table

#checkov:skip=CKV2_AWS_11:VPC flow logging disabled intentionally — cost decision for t3.nano single-instance setup
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = { Name = "portfolio-vpc" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = { Name = "portfolio-igw" }
}

#checkov:skip=CKV_AWS_130:Public subnet required — single EC2 serves public web traffic
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = { Name = "portfolio-public-subnet" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "portfolio-public-rt" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# CKV2_AWS_12: Restrict default VPC security group — deny all traffic
resource "aws_default_security_group" "default" {
  vpc_id = aws_vpc.main.id

  tags = { Name = "portfolio-default-sg-restricted" }
}
