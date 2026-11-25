#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ telco5g add-interface command ************"

# Use AWS credentials from the cluster profile
export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

# Install AWS CLI
curl -sL --retry 5 --retry-delay 10 "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscli.zip
echo "Extracting aws cli"
unzip -o /tmp/awscli.zip -d /tmp/ 1>/dev/null
echo "Insalling aws cli"
/tmp/aws/install --install-dir /tmp/aws-cli --bin-dir /tmp/bin 2>/dev/null
export PATH="/tmp/bin:/tmp:${PATH}"
aws --version

# Install terraform
TERRAFORM_VERSION="1.5.5"
curl -sL --retry 5 --retry-delay 10 "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip" -o /tmp/terraform.zip
echo "Extracting terraform"
unzip -o /tmp/terraform.zip -d /tmp/ 1>/dev/null
chmod +x /tmp/terraform
terraform version

INSTANCE_PREFIX="$(grep "name: ci-op-" "$SHARED_DIR/install-config.yaml" | sed "s/.*name: //g")"
if [[ -z "${INSTANCE_PREFIX}" ]]; then
    INSTANCE_PREFIX="$(grep "name: ci-op-" "$SHARED_DIR/kubeconfig" | sed "s/.*name: //g")"
fi
if [[ -z "${INSTANCE_PREFIX}" ]]; then
    echo "Can not find INSTANCE_PREFIX, exiting"
    exit 1
fi
echo "Detected INSTANCE_PREFIX=${INSTANCE_PREFIX}"

AWS_REGION=""
MASTER_INSTANCE_ID=""
for region in us-east-1 us-east-2 us-west-1 us-west-2; do
  result=$(aws ec2 describe-instances \
    --region "$region" \
    --filters "Name=tag:Name,Values=${INSTANCE_PREFIX}*" \
              "Name=instance-state-name,Values=running,stopped" \
    --query 'Reservations[].Instances[].[InstanceId,Tags[?Key==`Name`].Value|[0],State.Name,Placement.AvailabilityZone]' \
    --output text 2>/dev/null || true)
  if [[ -n "$result" ]]; then
    AWS_REGION="$region"
    echo "Found instance(s) with prefix ID ${INSTANCE_PREFIX}* in region: ${AWS_REGION}"
    echo "$result" | while read -r id name state az; do
      echo "  Instance: ${id}  Name: ${name}  State: ${state}  AZ: ${az}"
    done
    # Select the instance with "master" in its name
    MASTER_INSTANCE_ID=$(echo "$result" | awk '$2 ~ /master/ {print $1; exit}')
    echo "Found final master instance ID $MASTER_INSTANCE_ID"
    break
  fi
done

if [[ -z "$AWS_REGION" ]]; then
  echo "ERROR: Could not find instance with prefix '${INSTANCE_PREFIX}' in any US region"
  exit 1
fi

if [[ -z "$MASTER_INSTANCE_ID" ]]; then
  echo "ERROR: Could not find a master instance among the results"
  exit 1
fi

echo "Selected master instance: ${MASTER_INSTANCE_ID}"

# Save instance ID and region for the delete step
echo "${MASTER_INSTANCE_ID}" > ${SHARED_DIR}/telco5g-instance-id
echo "${AWS_REGION}" > ${SHARED_DIR}/telco5g-aws-region

cat << EOF > ${SHARED_DIR}/main.tf
provider "aws" {
  region = "${AWS_REGION}"
}

variable "instance_id" {
  description = "The EC2 instance ID to attach the secondary interface to"
  type        = string
}

data "aws_instance" "target_instance" {
  instance_id = var.instance_id
}

data "aws_subnet" "instance_subnet" {
  id = data.aws_instance.target_instance.subnet_id
}

resource "aws_subnet" "secondary_subnet" {
  vpc_id                  = data.aws_subnet.instance_subnet.vpc_id
  cidr_block              = "10.0.250.0/24"
  availability_zone       = data.aws_instance.target_instance.availability_zone
  map_public_ip_on_launch = false
  tags = {
    Name = "secondary-subnet"
  }
}

resource "aws_network_interface" "secondary_interface" {
  subnet_id       = aws_subnet.secondary_subnet.id
  private_ips     = ["10.0.250.10"]
  tags = {
    Name = "secondary-interface"
  }
}

resource "aws_network_interface_attachment" "attach_interface" {
  instance_id          = data.aws_instance.target_instance.id
  network_interface_id = aws_network_interface.secondary_interface.id
  device_index         = 1
}

EOF

cd ${SHARED_DIR}
terraform init
terraform apply -auto-approve -var="instance_id=${MASTER_INSTANCE_ID}"
