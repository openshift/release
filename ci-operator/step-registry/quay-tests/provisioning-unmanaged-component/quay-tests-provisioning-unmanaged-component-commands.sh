#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "omr secret"
ls -l /var/run/quay-qe-omr-secret/
touch quaybuilder quaybuilder.pub
cat /var/run/quay-qe-omr-secret/quaybuilder > quaybuilder && cat /var/run/quay-qe-omr-secret/quaybuilder.pub > quaybuilder.pub
chmod 600 ./quaybuilder && chmod 600 ./quaybuilder.pub && echo "" >> quaybuilder
echo "copy omr secret"
ls -l
cat quaybuilder

#Create AWS EC2 instance, S3 Storage Bucket, and AWS RDS Postgreql 16
QUAY_AWS_S3_BUCKET="quayprowcis3$RANDOM"
QUAY_SUBNET_GROUP="quayprowcisubnetgroup$RANDOM"
QUAY_SECURITY_GROUP="quayprowcisecuritygroup$RANDOM"

QUAY_AWS_ACCESS_KEY=$(cat /var/run/quay-qe-aws-secret/access_key)
QUAY_AWS_SECRET_KEY=$(cat /var/run/quay-qe-aws-secret/secret_key)
QUAY_AWS_RDS_POSTGRESQL_DBNAME=$(cat /var/run/quay-qe-aws-rds-postgresql-secret/dbname)
QUAY_AWS_RDS_POSTGRESQL_USERNAME=$(cat /var/run/quay-qe-aws-rds-postgresql-secret/username)
QUAY_AWS_RDS_POSTGRESQL_PASSWORD=$(cat /var/run/quay-qe-aws-rds-postgresql-secret/password)

QUAY_AWS_RDS_POSTGRESQL_VERSION="16.3"

#Create new directory to create terraform resources
mkdir -p terraform_aws_rds && cd terraform_aws_rds

cat >>variables.tf <<EOF
variable "region" {
  default = "us-east-2"
}
variable "quay_subnet_group" {
}
variable "quay_security_group" {
}
variable "aws_bucket" {
}
variable "quay_operator_key" {
  default = "quayprow_operator_key"
}
EOF

cat >>create_redis_aws_s3_postgresql.tf <<EOF

## EC2 instance for redis ##
provider "aws" {
  region = "us-east-2"
  access_key = "${QUAY_AWS_ACCESS_KEY}"
  secret_key = "${QUAY_AWS_SECRET_KEY}"
}
resource "aws_vpc" "quayoperatorci" {
  cidr_block       = "10.0.0.0/16"
  instance_tenancy = "default"
  enable_dns_support = true
  enable_dns_hostnames = true

  tags = {
    Name = "quayoperatorcitest"
  }
}
resource "aws_internet_gateway" "quayoperatorigw" {
  vpc_id = aws_vpc.quayoperatorci.id
}
resource "aws_route" "route-public" {
  route_table_id         = aws_vpc.quayoperatorci.main_route_table_id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.quayoperatorigw.id
}
resource "aws_subnet" "quayoperatorci" {
  vpc_id            = aws_vpc.quayoperatorci.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = "us-east-2b"
}

resource "aws_key_pair" "quayoperatorci" {
  key_name   = var.quay_operator_key
  public_key = file("./quaybuilder.pub")
}

resource "aws_security_group" "quayoperatorsecg" {
  name        = var.quay_security_group
  description = "Allow all inbound traffic"
  vpc_id      = aws_vpc.quayoperatorci.id
  ingress {
    description = "traffic into quayoperator VPC"
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

resource "aws_instance" "quayoperatorci" {
  key_name      = aws_key_pair.quayoperatorci.key_name
  ami           = "ami-0b2e47f3b2e23d235"
  instance_type = "m4.xlarge"

  associate_public_ip_address = true
  vpc_security_group_ids = [aws_security_group.quayoperatorsecg.id]
  subnet_id = aws_subnet.quayoperatorcisub.id
  
  ebs_block_device {
    device_name = "/dev/sda1"
    volume_size = 200
  }

  provisioner "remote-exec" {
    inline = [
      "sudo yum install podman -y",
      "mkdir -p ~/redis-quay",
      "sudo podman run -d  --name redis -p 6379:6379 -e REDIS_PASSWORD=redispw -v ~/redis-quay:/var/lib/redis/data:Z quay.io/quay-qetest/redis:latest"
    ]
  }

  connection {
    type        = "ssh"
    host        = self.public_ip
    user        = "ec2-user"
    private_key = file("./quaybuilder")
  }
  tags = {
    Name = "quayoperatorcitest"
  }
}

output "instance_public_ip" {
  value = aws_instance.quayoperatorci.public_ip
}


## DB ##
resource "aws_subnet" "quayoperatorci2" {
  vpc_id            = aws_vpc.quayoperatorci.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "us-east-2c"
}
resource "aws_db_subnet_group" "quayoperatorci" {
  name       = var.quay_subnet_group
  subnet_ids = [aws_subnet.quayoperatorci.id,aws_subnet.quayoperatorci2.id]
  tags = {
    Name = "Quay Operator subnet group"
  }
}
resource "aws_db_instance" "quaydb" {
  allocated_storage    = 30
  storage_type         = "gp2"
  engine               = "postgres"
  engine_version       = "${QUAY_AWS_RDS_POSTGRESQL_VERSION}"
  instance_class       = "db.m5.large"
  db_name              = "${QUAY_AWS_RDS_POSTGRESQL_DBNAME}"
  username             = "${QUAY_AWS_RDS_POSTGRESQL_USERNAME}"
  password             = "${QUAY_AWS_RDS_POSTGRESQL_PASSWORD}"
  publicly_accessible  = true
  skip_final_snapshot  = true
  db_subnet_group_name = aws_db_subnet_group.quayoperatorci.id
  vpc_security_group_ids = [aws_security_group.quayoperatorsecg.id]
}

output "quaydb_address" {
    value = aws_db_instance.quaydb.address
}
output "quaydb_endpint" {
    value = aws_db_instance.quaydb.endpoint
}
output "quaydb_name" {
    value = aws_db_instance.quaydb.db_name
}
output "quaydb_username" {
    value = aws_db_instance.quaydb.username
}

## Bucket ##
resource "aws_s3_bucket" "quayaws" {
  bucket = var.aws_bucket
  force_destroy = true
}
resource "aws_s3_bucket_ownership_controls" "quayaws" {
  bucket = aws_s3_bucket.quayaws.id
  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}
resource "aws_s3_bucket_acl" "quayaws_bucket_acl" {
  depends_on = [aws_s3_bucket_ownership_controls.quayaws]
  bucket = aws_s3_bucket.quayaws.id
  acl    = "private"
}

EOF

export TF_VAR_aws_bucket="${QUAY_AWS_S3_BUCKET}"
export TF_VAR_quay_subnet_group="${QUAY_SUBNET_GROUP}"
export TF_VAR_quay_security_group="${QUAY_SECURITY_GROUP}"
terraform --version
terraform init 
terraform apply -auto-approve 

QUAY_AWS_RDS_POSTGRESQL_ADDRESS=$(terraform output quaydb_address | tr -d '""' | tr -d '\n')

#Share the Terraform Var and Terraform Directory
tar -cvzf terraform.tgz --exclude=".terraform" *
cp terraform.tgz ${SHARED_DIR}
echo "${QUAY_AWS_S3_BUCKET}" >${SHARED_DIR}/QUAY_AWS_S3_BUCKET
echo "${QUAY_SUBNET_GROUP}" >${SHARED_DIR}/QUAY_SUBNET_GROUP
echo "${QUAY_SECURITY_GROUP}" >${SHARED_DIR}/QUAY_SECURITY_GROUP

cd .. && mkdir -p terraform_install_extension && cd terraform_install_extension

cat >>variables.tf <<EOF
variable "quay_db_host" {
}
EOF

cat >>install_extension.tf <<EOF
terraform {
  required_providers {
    postgresql = {
      source = "cyrilgdn/postgresql"
      version = "1.22.0"
    }
  }
}
provider "postgresql" {
  host            = var.quay_db_host
  username        = "${QUAY_AWS_RDS_POSTGRESQL_USERNAME}"
  password        = "${QUAY_AWS_RDS_POSTGRESQL_PASSWORD}"
  expected_version = "${QUAY_AWS_RDS_POSTGRESQL_VERSION}"
  sslmode         = "require"
  connect_timeout = 15
}

## Provision db for clair
resource "postgresql_database" "clairdb" {
  name              = "clair"
  connection_limit  = -1
  allow_connections = true
}
resource "postgresql_extension" "pg_trgm" {
  name     = "pg_trgm"
  database = "${QUAY_AWS_RDS_POSTGRESQL_DBNAME}"
}
resource "postgresql_extension" "uuid-ossp" {
  name     = "uuid-ossp"
  database = "clair"
  depends_on=[postgresql_database.clairdb]
}
EOF

export TF_VAR_quay_db_host="${QUAY_AWS_RDS_POSTGRESQL_ADDRESS}"
terraform init 
terraform apply -auto-approve 
