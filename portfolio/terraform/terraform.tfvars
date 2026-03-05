aws_region    = "us-east-1"
environment   = "production"
instance_type = "t3.nano"
key_pair_name = "portfolio-key"      # must already exist in AWS EC2 → Key Pairs
your_ip_cidr  = "REDACTED_IP/32"    # run: curl ifconfig.me
domain_name   = "rerktserver.com"
admin_email   = "REDACTED_EMAIL"