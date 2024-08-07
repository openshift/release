#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

#How to install trivy
#https://aquasecurity.github.io/trivy/v0.54/getting-started/installation/

#Create new AWS EC2 Instatnce to run Quay Security Testing
QUAY_AWS_ACCESS_KEY=$(cat /var/run/quay-qe-omr-secret/access_key)
QUAY_AWS_SECRET_KEY=$(cat /var/run/quay-qe-omr-secret/secret_key)

#Retrieve the Credentials of image registry "brew.registry.redhat.io"
QUAY_BREW_USERNAME=$(cat /var/run/quay-qe-brew-secret/username)
QUAY_BREW_PASSWORD=$(cat /var/run/quay-qe-brew-secret/password)

QUAY_SECURITY_TESTING_NAME="quaysecuritytesting$RANDOM"
mkdir -p terraform_quay_security && cd terraform_quay_security

cat >>variables.tf <<EOF
variable "quay_build_worker_key" {
}
variable "quay_build_worker_security_group" {
}
variable "quay_build_instance_name" {
}
EOF

cat >>create_aws_ec2.tf <<EOF
provider "aws" {
  region = "us-east-2"
  access_key = "${QUAY_AWS_ACCESS_KEY}"
  secret_key = "${QUAY_AWS_SECRET_KEY}"
}

resource "aws_vpc" "quaybuilder" {
  cidr_block           = "10.0.0.0/16"
  instance_tenancy     = "default"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = {
    Name = "quaytrivy"
  }

}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.quaybuilder.id
}

resource "aws_route" "route-public" {
  route_table_id         = aws_vpc.quaybuilder.main_route_table_id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.igw.id
}

resource "aws_subnet" "quaybuilder" {
  vpc_id            = aws_vpc.quaybuilder.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = "us-east-2a"
}

resource "aws_key_pair" "quaybuilder0710" {
  key_name   = var.quay_build_worker_key
  public_key = file("./quaybuilder.pub")
}

resource "aws_security_group" "quaybuilder" {
  name        = var.quay_build_worker_security_group
  description = "Allow all inbound traffic"
  vpc_id      = aws_vpc.quaybuilder.id

  ingress {
    description = "traffic into quaybuilder VPC"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

}

resource "aws_instance" "quaybuilder" {
  key_name = aws_key_pair.quaybuilder0710.key_name
  ami      = "ami-02b8534ff4b424939"
  instance_type = "m4.xlarge"

  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.quaybuilder.id]
  subnet_id                   = aws_subnet.quaybuilder.id

  ebs_block_device {
    device_name = "/dev/sda1"
    volume_size = 200
  }

  provisioner "remote-exec" {
    inline = [
      "sudo yum install -y podman",
      "sudo rpm -ivh https://github.com/aquasecurity/trivy/releases/download/v0.54.1/trivy_0.54.1_Linux-64bit.rpm",
      "sudo podman login -u '${QUAY_BREW_USERNAME}' -p ${QUAY_BREW_PASSWORD} brew.registry.redhat.io",
      "sudo trivy image brew.registry.redhat.io/rh-osbs/quay-quay-rhel8:v3.12.1-8 --username '${QUAY_BREW_USERNAME}' --password ${QUAY_BREW_PASSWORD} || true"
    ]
  }

  connection {
    type        = "ssh"
    host        = self.public_ip
    user        = "ec2-user"
    private_key = file("./quaybuilder")
  }
  tags = {
    Name = var.quay_build_instance_name
  }
}
output "instance_public_dns" {
  value = aws_instance.quaybuilder.public_dns
}
EOF

cp /var/run/quay-qe-omr-secret/quaybuilder . && cp /var/run/quay-qe-omr-secret/quaybuilder.pub .
chmod 600 ./quaybuilder && chmod 600 ./quaybuilder.pub

export TF_VAR_quay_build_instance_name="${QUAY_SECURITY_TESTING_NAME}"
export TF_VAR_quay_build_worker_key="${QUAY_SECURITY_TESTING_NAME}"
export TF_VAR_quay_build_worker_security_group="${QUAY_SECURITY_TESTING_NAME}"
terraform init
terraform apply -auto-approve

#Share the OMR HOSTNAME, Terraform Var and Terraform Directory
tar -cvzf terraform.tgz --exclude=".terraform" *
cp terraform.tgz ${SHARED_DIR}

#Use Terraform to output the Public DNS Name of Quay OMR
QUAY_SECURITY_TESTING_HOST_NAME=$(terraform output instance_public_dns | tr -d '"')
echo "QUAY SECURITY TESTING HOST NAME is $QUAY_SECURITY_TESTING_HOST_NAME"

echo "${QUAY_SECURITY_TESTING_HOST_NAME}" >${SHARED_DIR}/QUAY_SECURITY_TESTING_HOST_NAME
echo "${QUAY_SECURITY_TESTING_NAME}" >${SHARED_DIR}/QUAY_SECURITY_TESTING_NAME
