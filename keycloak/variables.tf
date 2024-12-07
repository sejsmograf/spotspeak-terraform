variable "aws_region" {
  default = "eu-central-1"
}


variable "ami" {
  type    = string
  default = "ami-0084a47cc718c111a" # Ubuntu 24.04
}

variable "instance_type" {
  type    = string
  default = "t2.small"
}


variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}


variable "subnet_count" {
  type = map(number)

  default = {
    public = 1,
  }
}

variable "public_subnet_cidr" {
  type = list(string)

  default = [
    "10.0.1.0/24",
    "10.0.2.0/24",
    "10.0.3.0/24",
    "10.0.4.0/24",
  ]
}



variable "ec2_key_path" {
  type      = string
  sensitive = true
}
