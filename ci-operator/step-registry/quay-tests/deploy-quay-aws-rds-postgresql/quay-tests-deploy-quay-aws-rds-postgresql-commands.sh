#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

#Create AWS S3 Storage Bucket, and AWS RDS Postgreql database with default version 16
QUAY_OPERATOR_CHANNEL="$QUAY_OPERATOR_CHANNEL"
QUAY_OPERATOR_SOURCE="$QUAY_OPERATOR_SOURCE"
QUAY_AWS_S3_BUCKET="quayprowcis3$RANDOM"
QUAY_SUBNET_GROUP="quayprowcisubnetgroup$RANDOM"
QUAY_SECURITY_GROUP="quayprowcisecuritygroup$RANDOM"

QUAY_AWS_RDS_POSTGRESQL_VERSION="$POSTGRESQL_VERSION"

QUAY_AWS_ACCESS_KEY=$(cat /var/run/quay-qe-aws-secret/access_key)
QUAY_AWS_SECRET_KEY=$(cat /var/run/quay-qe-aws-secret/secret_key)
QUAY_AWS_RDS_POSTGRESQL_DBNAME=$(cat /var/run/quay-qe-aws-rds-postgresql-secret/dbname)
QUAY_AWS_RDS_POSTGRESQL_USERNAME=$(cat /var/run/quay-qe-aws-rds-postgresql-secret/username)
QUAY_AWS_RDS_POSTGRESQL_PASSWORD=$(cat /var/run/quay-qe-aws-rds-postgresql-secret/password)


cat >>aws_rds_postgresql_parameter_groups.json <<EOF
{
  "aws": {
    "rds": {
      "postgresql": {
        "16": {
          "parameter_group": "scram-passwords-postgresql16"
        },
        "15": {
          "parameter_group": "scram-passwords-postgresql15"
        },
        "14": {
          "parameter_group": "scram-passwords-postgresql14"
        },
        "13": {
          "parameter_group": "scram-passwords"
        }
      }
    }
  }
}
EOF

AWS_RDS_PARAMETER_GROUP=$(jq -r .aws.rds.postgresql[\"${QUAY_AWS_RDS_POSTGRESQL_VERSION}\"].parameter_group <aws_rds_postgresql_parameter_groups.json)
echo "The current using database parameter group is $AWS_RDS_PARAMETER_GROUP"

#Create new directory to create terraform resources
mkdir -p terraform_aws_rds && cd terraform_aws_rds

cat >>variables.tf <<EOF
variable "region" {
  default = "us-west-2"
}

variable "quay_subnet_group" {

}

variable "quay_security_group" {

}

variable "aws_bucket" {

}
EOF

cat >>create_aws_s3_rds_postgresql.tf <<EOF
provider "aws" {
  region = "us-west-2"
  access_key = "${QUAY_AWS_ACCESS_KEY}"
  secret_key = "${QUAY_AWS_SECRET_KEY}"
}

resource "aws_vpc" "quayrds" {
  cidr_block       = "10.0.0.0/16"
  instance_tenancy = "default"
  enable_dns_support = true
  enable_dns_hostnames = true

}

resource "aws_internet_gateway" "quaydbigw" {
  vpc_id = aws_vpc.quayrds.id
}

resource "aws_route" "route-public" {
  route_table_id         = aws_vpc.quayrds.main_route_table_id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.quaydbigw.id
}

resource "aws_subnet" "quayrds1" {
  vpc_id            = aws_vpc.quayrds.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = "us-west-2b"
}

resource "aws_subnet" "quayrds2" {
  vpc_id            = aws_vpc.quayrds.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "us-west-2c"
}

resource "aws_db_subnet_group" "quayrds" {
  name       = var.quay_subnet_group
  subnet_ids = [aws_subnet.quayrds1.id,aws_subnet.quayrds2.id]

  tags = {
    Name = "Quay DB subnet group"
  }
}

resource "aws_security_group" "quayrds" {
  name        = var.quay_security_group
  description = "Allow all inbound traffic"
  vpc_id      = aws_vpc.quayrds.id

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

resource "aws_db_instance" "quaydb" {
  allocated_storage    = 30
  storage_type         = "gp2"
  engine               = "postgres"
  engine_version       = "${QUAY_AWS_RDS_POSTGRESQL_VERSION}"
  instance_class       = "db.m5.large"
  db_name              = "${QUAY_AWS_RDS_POSTGRESQL_DBNAME}"
  username             = "${QUAY_AWS_RDS_POSTGRESQL_USERNAME}"
  password             = "${QUAY_AWS_RDS_POSTGRESQL_PASSWORD}"
  parameter_group_name = "${AWS_RDS_PARAMETER_GROUP}"
  publicly_accessible  = true
  skip_final_snapshot  = true
  db_subnet_group_name = aws_db_subnet_group.quayrds.id
  vpc_security_group_ids = [aws_security_group.quayrds.id]
}

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

output "quaydb_password" {
    value = aws_db_instance.quaydb.password
    sensitive = true
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

resource "postgresql_extension" "pg_trgm" {
  name     = "pg_trgm"
  database = "${QUAY_AWS_RDS_POSTGRESQL_DBNAME}"
}
EOF

export TF_VAR_quay_db_host="${QUAY_AWS_RDS_POSTGRESQL_ADDRESS}"
terraform init 
terraform apply -auto-approve 

#Deploy Quay Operator to OCP namespace 'quay-enterprise'
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: quay-enterprise
EOF

cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: quay
  namespace: quay-enterprise
spec:
  targetNamespaces:
  - quay-enterprise
EOF

SUB=$(
  cat <<EOF | oc apply -f - -o jsonpath='{.metadata.name}'
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: quay-operator
  namespace: quay-enterprise
spec:
  installPlanApproval: Automatic
  name: quay-operator
  channel: $QUAY_OPERATOR_CHANNEL
  source: $QUAY_OPERATOR_SOURCE
  sourceNamespace: openshift-marketplace
EOF
)

echo "The Quay Operator subscription is $SUB"

for _ in {1..60}; do
  CSV=$(oc -n quay-enterprise get subscription quay-operator -o jsonpath='{.status.installedCSV}' || true)
  if [[ -n "$CSV" ]]; then
    if [[ "$(oc -n quay-enterprise get csv "$CSV" -o jsonpath='{.status.phase}')" == "Succeeded" ]]; then
      echo "ClusterServiceVersion \"$CSV\" ready"
      break
    fi
  fi
  sleep 10
done
echo "Quay Operator is deployed successfully"

#Deploy Quay, here disable monitoring component
cat >>config.yaml <<EOF
CREATE_PRIVATE_REPO_ON_PUSH: true
CREATE_NAMESPACE_ON_PUSH: true
FEATURE_EXTENDED_REPOSITORY_NAMES: true
FEATURE_QUOTA_MANAGEMENT: true
FEATURE_PROXY_CACHE: true
FEATURE_USER_INITIALIZE: true
SUPER_USERS:
  - quay
USERFILES_LOCATION: default
USERFILES_PATH: userfiles/
DISTRIBUTED_STORAGE_DEFAULT_LOCATIONS:
  - default
DISTRIBUTED_STORAGE_PREFERENCE:
  - default
DISTRIBUTED_STORAGE_CONFIG:
  default:
    - S3Storage
    - s3_bucket: $QUAY_AWS_S3_BUCKET
      storage_path: /quay
      s3_access_key: $QUAY_AWS_ACCESS_KEY
      s3_secret_key: $QUAY_AWS_SECRET_KEY
      host: s3.us-west-2.amazonaws.com
      s3_region: us-west-2
DB_CONNECTION_ARGS:
  autorollback: true
  threadlocals: true
DB_URI: postgresql://$QUAY_AWS_RDS_POSTGRESQL_USERNAME:$QUAY_AWS_RDS_POSTGRESQL_PASSWORD@$QUAY_AWS_RDS_POSTGRESQL_ADDRESS:5432/$QUAY_AWS_RDS_POSTGRESQL_DBNAME
EOF

oc create secret generic -n quay-enterprise --from-file config.yaml=./config.yaml config-bundle-secret

echo "Creating Quay registry..." >&2
cat <<EOF | oc apply -f -
apiVersion: quay.redhat.com/v1
kind: QuayRegistry
metadata:
  name: quay
  namespace: quay-enterprise
spec:
  configBundleSecret: config-bundle-secret
  components:
  - kind: objectstorage
    managed: false
  - kind: monitoring
    managed: false
  - kind: postgres
    managed: false
  - kind: horizontalpodautoscaler
    managed: true
  - kind: quay
    managed: true
  - kind: mirror
    managed: true
  - kind: clair
    managed: true
  - kind: tls
    managed: true
  - kind: route
    managed: true
EOF

for _ in {1..60}; do
  if [[ "$(oc -n quay-enterprise get quayregistry quay -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' || true)" == "True" ]]; then
    echo "Quay is in ready status" >&2
    exit 0
  fi
  sleep 15
done
echo "Timed out waiting for Quay to become ready afer 15 mins" >&2
oc -n quay-enterprise get quayregistries -o yaml >"$ARTIFACT_DIR/quayregistries.yaml"
