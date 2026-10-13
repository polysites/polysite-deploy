# One EC2 instance running the cloud-init file next to this folder, an Elastic IP, and a security group with 22 (yours), 80 and 443.
# It creates no database (the stack's own PostgreSQL container is used: see the guide for RDS) and no DNS records.
# Review before applying: terraform init && terraform plan -var site_domain=... -var admin_domain=... -var ssh_cidr=...

data "aws_ssm_parameter" "ubuntu" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

resource "aws_security_group" "polysite" {
  name_prefix = "polysite-"
  description = "Polysite: SSH from one address, http and https from anywhere"

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_cidr]
  }
  ingress {
    description      = "http (certificate challenge and redirect)"
    from_port        = 80
    to_port          = 80
    protocol         = "tcp"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }
  ingress {
    description      = "https"
    from_port        = 443
    to_port          = 443
    protocol         = "tcp"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }
  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }
}

resource "aws_instance" "polysite" {
  ami                    = data.aws_ssm_parameter.ubuntu.value
  instance_type          = var.instance_type
  key_name               = var.ssh_key_name == "" ? null : var.ssh_key_name
  vpc_security_group_ids = [aws_security_group.polysite.id]

  # The cloud-init file with your two domains put in.
  user_data = replace(replace(file("${path.module}/../cloud-init.yaml"), "www.example.org", var.site_domain), "admin.example.org", var.admin_domain)

  root_block_device {
    volume_type = "gp3"
    volume_size = var.disk_gb
    encrypted   = true
  }

  metadata_options {
    http_tokens = "required" # IMDSv2 only
  }

  tags = { Name = "polysite" }
}

resource "aws_eip" "polysite" {
  instance = aws_instance.polysite.id
  domain   = "vpc"
}
