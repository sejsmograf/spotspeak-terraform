terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.16"
    }
  }

  required_version = ">= 1.2.0"
}


provider "aws" {
  region = var.aws_region
}


data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "vpc" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.vpc.id
}

resource "aws_subnet" "public_subnet" {
  vpc_id = aws_vpc.vpc.id
  count  = var.subnet_count.public

  cidr_block = var.public_subnet_cidr[count.index]

  availability_zone = data.aws_availability_zones.available.names[count.index]
}

resource "aws_subnet" "private_subnet" {
  vpc_id = aws_vpc.vpc.id
  count  = var.subnet_count.private

  cidr_block = var.private_subnet_cidr[count.index]

  availability_zone = data.aws_availability_zones.available.names[count.index]
}


resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
}

resource "aws_route_table_association" "public_rta" {
  count = var.subnet_count.public

  route_table_id = aws_route_table.public_rt.id
  subnet_id      = aws_subnet.public_subnet[count.index].id
}

resource "aws_route_table" "private_rt" {
  vpc_id = aws_vpc.vpc.id
}

resource "aws_route_table_association" "private_rta" {
  count = var.subnet_count.private

  route_table_id = aws_route_table.private_rt.id
  subnet_id      = aws_subnet.private_subnet[count.index].id
}

resource "aws_security_group" "web_sg" {
  name   = "web_sg"
  vpc_id = aws_vpc.vpc.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

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

resource "aws_security_group" "rds_sg" {
  vpc_id = aws_vpc.vpc.id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.web_sg.id]
  }
}

resource "aws_db_subnet_group" "db_subnet_group" {
  subnet_ids = [for subnet in aws_subnet.private_subnet : subnet.id]
}

resource "aws_db_instance" "db" {
  allocated_storage = 10
  engine            = "postgres"
  instance_class    = "db.t3.micro"


  username = var.db_username
  password = var.db_password

  db_subnet_group_name   = aws_db_subnet_group.db_subnet_group.id
  vpc_security_group_ids = [aws_security_group.rds_sg.id]

  skip_final_snapshot = true
}

resource "aws_s3_bucket" "bucket" {
  bucket        = var.bucket_name
  force_destroy = true
}

resource "aws_s3_bucket_policy" "example" {
  bucket = aws_s3_bucket.bucket.id

  policy = jsonencode({
    Version = "2008-10-17"
    Id      = "PolicyForCloudFrontPrivateContent"
    Statement = [
      {
        Sid    = "AllowCloudFrontServicePrincipal"
        Effect = "Allow"
        Principal = {
          Service = "cloudfront.amazonaws.com"
        }
        Action   = "s3:GetObject"
        Resource = "${aws_s3_bucket.bucket.arn}/*"
        Condition = {
          StringEquals = {
            "AWS:SourceArn" = "arn:aws:cloudfront::${data.aws_caller_identity.current.account_id}:distribution/${aws_cloudfront_distribution.cdn.id}"
          }
        }
      }
    ]
  })
}


resource "aws_cloudfront_origin_access_control" "oac" {
  name        = "example-oac"
  description = "Origin Access Control for S3"

  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "cdn" {

  price_class = "PriceClass_100"

  origin {
    domain_name = aws_s3_bucket.bucket.bucket_regional_domain_name
    origin_id   = "S3-${aws_s3_bucket.bucket.id}"

    origin_access_control_id = aws_cloudfront_origin_access_control.oac.id
  }

  enabled = true

  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "S3-${aws_s3_bucket.bucket.id}"

    forwarded_values {
      query_string = false

      cookies {
        forward = "none"
      }
    }
    viewer_protocol_policy = "redirect-to-https"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}


resource "aws_key_pair" "ec2_key" {
  key_name = "spotspeak-key"

  public_key = file(var.ec2_key_path)
}

resource "aws_iam_role" "ec2_role" {
  name = "ec2_s3_full_access_role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_policy" "s3_full_access" {
  name        = "S3FullAccessPolicy"
  description = "Policy that allows full access to a specific S3 bucket"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "s3:*"
        Effect = "Allow"
        Resource = [
          "${aws_s3_bucket.bucket.arn}",
          "${aws_s3_bucket.bucket.arn}/*",
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ec2_s3_full_access" {
  policy_arn = aws_iam_policy.s3_full_access.arn
  role       = aws_iam_role.ec2_role.name
}


resource "aws_instance" "server" {
  count         = 1
  ami           = var.ami
  instance_type = var.instance_type
  subnet_id     = aws_subnet.public_subnet[count.index].id

  key_name = aws_key_pair.ec2_key.key_name

  vpc_security_group_ids = [aws_security_group.web_sg.id]

  user_data                   = <<-EOF
              #!/bin/bash
              apt-get update -y
              apt-get install -y git
              apt-get install -y postgresql 
              apt-get install -y ca-certificates curl

              install -m 0755 -d /etc/apt/keyrings
              curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
              chmod a+r /etc/apt/keyrings/docker.asc

              # Add the repository to Apt sources:
              echo \
                "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
                $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
                tee /etc/apt/sources.list.d/docker.list > /dev/null
              apt-get update -y

              apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
              
              systemctl enable docker
              systemctl start docker
              echo "export ENV_SPRING_DATASOURCE_URL=jdbc:postgresql://${aws_db_instance.db.address}/postgres" >> /home/ubuntu/.bashrc
              echo "export ENV_SPRING_DATASOURCE_USERNAME=${var.db_username}" >> /home/ubuntu/.bashrc
              echo "export ENV_SPRING_DATASOURCE_PASSWORD=${var.db_password}" >> /home/ubuntu/.bashrc
              echo "export KEYCLOAK_CLIENT_ID=" >> /home/ubuntu/.bashrc
              echo "export KEYCLOAK_CLIENT_SECRET=" >> /home/ubuntu/.bashrc
              echo "export AWS_S3_BUCKET_NAME=${aws_s3_bucket.bucket.bucket}" >> /home/ubuntu/.bashrc
              echo "export AWS_CLOUDFRONT_URL=${aws_cloudfront_distribution.cdn.domain_name}" >> /home/ubuntu/.bashrc
              echo "export GROQ_API_KEY=" >> /home/ubuntu/.bashrc
              echo "export GROQ_BASE_URL=" >> /home/ubuntu/.bashrc
              echo "export GROQ_CHAT_MODEL=" >> /home/ubuntu/.bashrc
              echo "export SERVER_PORT=80" >> /home/ubuntu/.bashrc
              echo "export EC2_ENV=true" >> /home/ubuntu/.bashrc

              usermod -aG docker ubuntu
              sudo systemctl restart docker
              newgrp docker

              apt install -y nginx certbot python3-certbot-nginx
              
              su - ubuntu -c "git clone https://github.com/sejsmograf/spotspeak /home/ubuntu/spotspeak"
              EOF
  user_data_replace_on_change = true
}

resource "aws_eip" "eip" {
  count = 1

  instance = aws_instance.server[count.index].id
  vpc      = true
}


data "aws_caller_identity" "current" {}


output "database_address" {
  value = aws_db_instance.db.address
}

output "database_port" {
  value = aws_db_instance.db.port
}

output "cloudfront_domain_name" {
  value = aws_cloudfront_distribution.cdn.domain_name
}

output "server_eip" {
  value = aws_eip.eip[0].public_ip
}
