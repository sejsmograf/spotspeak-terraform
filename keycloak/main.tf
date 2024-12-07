terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.16"
    }
  }

  backend "s3" {}

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

resource "aws_security_group" "keycloak_sg" {
  name   = "keycloak-sg"
  vpc_id = aws_vpc.vpc.id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

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


resource "aws_key_pair" "ec2_key" {
  key_name = "keycloak-key"

  public_key = file(var.ec2_key_path)
}


resource "aws_instance" "server" {
  count         = 1
  ami           = var.ami
  instance_type = var.instance_type
  subnet_id     = aws_subnet.public_subnet[count.index].id

  key_name = aws_key_pair.ec2_key.key_name

  vpc_security_group_ids = [aws_security_group.keycloak_sg.id]

  user_data                   = <<-EOF
              #!/bin/bash
              apt-get update -y
              apt-get install -y git

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

              usermod -aG docker ubuntu
              sudo systemctl restart docker
              newgrp docker


              apt install -y nginx certbot python3-certbot-nginx
              su - ubuntu -c "git clone https://github.com/sejsmograf/spotspeak-keycloak /home/ubuntu/keycloak"
              EOF
  user_data_replace_on_change = true
}

resource "aws_eip" "eip" {
  count = 1

  instance = aws_instance.server[count.index].id
}


output "keycloak_eip" {
  value = aws_eip.eip[0].public_ip
}
