#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail


#Check podman and skopeo version
podman -v
skopeo -v
HOME_PATH=$(pwd) && echo $HOME_PATH

#Create new AWS EC2 Instatnce to deploy Quay OMR
OMR_AWS_ACCESS_KEY=$(cat /var/run/quay-qe-omr-secret/access_key)
OMR_AWS_SECRET_KEY=$(cat /var/run/quay-qe-omr-secret/secret_key)
OMR_CI_NAME="omrprowci$RANDOM"
OMR_HOST_NAME="quayomrcitest$RANDOM.qe.devcluster.openshift.com"

mkdir -p terraform_omr && cd terraform_omr

cat >> variables.tf << EOF
variable "quay_build_worker_key" {

}

variable "quay_build_worker_security_group" {

}

variable "quay_build_instance_name" {

}
EOF

cat >> create_aws_ec2.tf << EOF
provider "aws" {
  region = "us-east-2"
  access_key = "${OMR_AWS_ACCESS_KEY}"
  secret_key = "${OMR_AWS_SECRET_KEY}"
}

resource "aws_vpc" "quaybuilder" {
  cidr_block       = "10.0.0.0/16"
  instance_tenancy = "default"
  enable_dns_support = true
  enable_dns_hostnames = true
  
  tags = {
    Name = "${OMR_HOST_NAME}"
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
  availability_zone = "us-east-2c"
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
  key_name      = aws_key_pair.quaybuilder0710.key_name
  ami           = "ami-0b2e47f3b2e23d235"
  instance_type = "m4.xlarge"

  associate_public_ip_address = true
  vpc_security_group_ids = [aws_security_group.quaybuilder.id]
  subnet_id = aws_subnet.quaybuilder.id
  
  ebs_block_device {
    device_name = "/dev/sda1"
    volume_size = 200
  }

  provisioner "remote-exec" {
    inline = [
      "sudo yum install podman openssl -y",
      "curl -L -o mirror-registry.tar.gz https://developers.redhat.com/content-gateway/rest/mirror/pub/openshift-v4/clients/mirror-registry/latest/mirror-registry.tar.gz",
      "tar -xzvf mirror-registry.tar.gz",
      "sudo ./mirror-registry install --quayHostname ${OMR_HOST_NAME} --initPassword password --initUser quay -v"

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
resource "aws_route53_record" "quayomr" {
  zone_id = "Z3B3KOVA3TRCWP"
  name    = "${OMR_HOST_NAME}"
  type    = "A"
  ttl     = 300
  records = [aws_instance.quaybuilder.public_ip]
}

output "instance_public_ip" {
  value = aws_instance.quaybuilder.public_ip
}
EOF

cp /var/run/quay-qe-omr-secret/quaybuilder . && cp /var/run/quay-qe-omr-secret/quaybuilder.pub .
chmod 600 ./quaybuilder && chmod 600 ./quaybuilder.pub && echo "" >> quaybuilder

export TF_VAR_quay_build_instance_name="${OMR_CI_NAME}"
export TF_VAR_quay_build_worker_key="${OMR_CI_NAME}"
export TF_VAR_quay_build_worker_security_group="${OMR_CI_NAME}"
terraform init
terraform apply -auto-approve

#Share the OMR HOSTNAME, Terraform Var and Terraform Directory
tar -cvzf terraform.tgz --exclude=".terraform" *
cp terraform.tgz ${SHARED_DIR}
echo "${OMR_HOST_NAME}" > ${SHARED_DIR}/OMR_HOST_NAME
echo "${OMR_CI_NAME}" > ${SHARED_DIR}/OMR_CI_NAME

#Share the CA Cert of Quay OMR
scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/tmp/ssh_known_hosts -o VerifyHostKeyDNS=no -o ConnectionAttempts=3 -i quaybuilder ec2-user@"${OMR_HOST_NAME}":/etc/quay-install/quay-rootCA/rootCA.pem ${SHARED_DIR} || true
ls ${SHARED_DIR}

#Test OMR by push image
skopeo copy docker://docker.io/fedora@sha256:895cdfba5eb6a009a26576cb2a8bc199823ca7158519e36e4d9effcc8b951b47 docker://"${OMR_HOST_NAME}":8443/quaytest/test:latest --dest-tls-verify=false --dest-creds quay:password || true