provider "aws" {
  region = "us-east-1"
}

# 1. IAM Policy
resource "aws_iam_policy" "gcp_wif_policy" {
  name   = "GCPWIFAccessPolicy"
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect   = "Allow",
        Action   = "sts:GetCallerIdentity",
        Resource = "*"
      }
    ]
  })
}

# 2. IAM Role + Trust Policy for EC2
resource "aws_iam_role" "gcp_wif_role" {
  name = "GCPWIFAccessRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Principal = {
          Service = "ec2.amazonaws.com"
        },
        Action = "sts:AssumeRole"
      }
    ]
  })
}

# Attach policy to role
resource "aws_iam_role_policy_attachment" "gcp_wif_attach" {
  role       = aws_iam_role.gcp_wif_role.name
  policy_arn = aws_iam_policy.gcp_wif_policy.arn
}

# 3. Instance profile
resource "aws_iam_instance_profile" "gcp_wif_instance_profile" {
  name = "GCPWIFInstanceProfile"
  role = aws_iam_role.gcp_wif_role.name
}

# 4. Security group - allow SSH from anywhere
resource "aws_security_group" "gcp_wif_sg" {
  name        = "gcp-wif-sg"
  description = "Allow SSH"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# 5. Get latest Amazon Linux 2023 AMI
data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["137112412989"] # Amazon

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-kernel-6.1-x86_64"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

# 6. Get default VPC and subnet
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }

  filter {
    name   = "availability-zone"
    values = ["us-east-1a"]
  }
}

# 7. EC2 Instance with gcloud CLI in user_data
resource "aws_instance" "gcp_wif_instance" {
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = "t3.micro"
  subnet_id              = data.aws_subnets.default.ids[0]
  vpc_security_group_ids = [aws_security_group.gcp_wif_sg.id]
  iam_instance_profile   = aws_iam_instance_profile.gcp_wif_instance_profile.name

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  tags = {
    Name = "gcp-wif"
  }

  user_data = <<-EOF
              #!/bin/bash
              yum install -y curl unzip python3
              runuser -l ec2-user -c "
                cd /home/ec2-user
                curl -O https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-529.0.0-linux-x86_64.tar.gz
                tar -xf google-cloud-cli-529.0.0-linux-x86_64.tar.gz
                ./google-cloud-sdk/install.sh --quiet
                echo 'source ~/google-cloud-sdk/path.bash.inc' >> ~/.bashrc
              "
}
