#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

#Check podman and skopeo version
podman -v
skopeo -v
HOME_PATH=$(pwd) && echo $HOME_PATH

# ─── Build-from-source path: install OMR directly on the bastion host ───
if [ "${OMR_FROM_SOURCE}" = true ]; then
  echo "=== OMR build-from-source: installing on bastion host ==="

  # Read bastion details from SHARED_DIR (created by aws-provision-bastionhost)
  BASTION_PUBLIC=$(cat "${SHARED_DIR}/bastion_public_address")
  BASTION_PRIVATE=$(cat "${SHARED_DIR}/bastion_private_address")
  BASTION_SSH_USER=$(cat "${SHARED_DIR}/bastion_ssh_user")
  SSH_KEY="${CLUSTER_PROFILE_DIR}/ssh-privatekey"
  SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=30 -o ConnectionAttempts=3"

  echo "Bastion public: ${BASTION_PUBLIC}"
  echo "Bastion private: ${BASTION_PRIVATE}"

  # Step 1: Extract mirror-registry.tar.gz from CI-built pipeline image
  echo "Extracting mirror-registry.tar.gz from CI-built pipeline image..."
  MIRROR_REGISTRY_PULLSPEC=$(oc get istag pipeline:mirror-registry -o jsonpath='{.image.dockerImageReference}')
  echo "Resolved pipeline image: ${MIRROR_REGISTRY_PULLSPEC}"
  oc image extract "${MIRROR_REGISTRY_PULLSPEC}" \
    --path /mirror-registry.tar.gz:/tmp \
    --confirm --insecure \
    --registry-config="/var/run/ci-credentials/registry/.dockerconfigjson"
  ls -lh /tmp/mirror-registry.tar.gz

  # Step 2: SCP the tar.gz to the bastion host
  echo "Uploading mirror-registry.tar.gz to bastion..."
  scp ${SSH_OPTS} -i "${SSH_KEY}" \
    /tmp/mirror-registry.tar.gz \
    "${BASTION_SSH_USER}@${BASTION_PUBLIC}:/tmp/mirror-registry.tar.gz"

  # Clean up local copy
  rm -f /tmp/mirror-registry.tar.gz

  # Step 3: Validate bastion address is available for OMR hostname
  if [[ -z "${BASTION_PRIVATE}" ]]; then
    echo "ERROR: bastion_private_address is empty. Check aws-provision-bastionhost output."
    exit 1
  fi

  # Step 4: Install OMR on the bastion
  echo "Installing mirror-registry on bastion (using bastion private address: ${BASTION_PRIVATE})..."
  ssh ${SSH_OPTS} -i "${SSH_KEY}" \
    "${BASTION_SSH_USER}@${BASTION_PUBLIC}" \
    "sudo bootc usroverlay && \
     sudo yum install -y podman openssl && \
     cd /tmp && \
     tar -xzf mirror-registry.tar.gz && \
     chmod +x mirror-registry && \
     ./mirror-registry --version && \
     sudo ./mirror-registry install \
       --quayHostname ${BASTION_PRIVATE} \
       --quayRoot /var/lib/quay \
       --initPassword password \
       --initUser quay -v"

  # Step 5: Save the OMR endpoint for downstream steps
  # Downstream steps (mirror-images-oc-mirror, ipi-conf-mirror) read OMR_HOST_NAME
  echo "${BASTION_PRIVATE}" > "${SHARED_DIR}/OMR_HOST_NAME"
  echo "omr-bastion" > "${SHARED_DIR}/OMR_CI_NAME"

  # Save the CA cert from the bastion
  scp ${SSH_OPTS} -i "${SSH_KEY}" \
    "${BASTION_SSH_USER}@${BASTION_PUBLIC}:/var/lib/quay/quay-rootCA/rootCA.pem" \
    "${SHARED_DIR}/rootCA.pem" || true

  # Create an empty terraform.tgz so recycle-omr doesn't fail
  tar -czf "${SHARED_DIR}/terraform.tgz" --files-from /dev/null

  # Test OMR by pushing a test image
  echo "Testing OMR push via bastion..."
  skopeo copy \
    docker://docker.io/fedora@sha256:895cdfba5eb6a009a26576cb2a8bc199823ca7158519e36e4d9effcc8b951b47 \
    docker://"${BASTION_PRIVATE}":8443/quaytest/test:latest \
    --dest-tls-verify=false --dest-creds quay:password || true

  echo "=== OMR build-from-source installation complete ==="
  exit 0
fi

# ─── Legacy path: create a separate EC2 instance via Terraform ───

#Create new AWS EC2 Instance to deploy Quay OMR
OMR_AWS_ACCESS_KEY=$(cat /var/run/quay-qe-omr-secret/access_key)
OMR_AWS_SECRET_KEY=$(cat /var/run/quay-qe-omr-secret/secret_key)

#Retrieve the Credentials of image registry "brew.registry.redhat.io"
OMR_BREW_USERNAME=$(cat /var/run/quay-qe-brew-secret/username)
OMR_BREW_PASSWORD=$(cat /var/run/quay-qe-brew-secret/password)
if [ -z "${OMR_IMAGE_ENV+x}" ]; then
    OMR_IMAGE_TAG="${MULTISTAGE_PARAM_OVERRIDE_OMR_IMAGE}"
else
   OMR_IMAGE_TAG="brew.registry.redhat.io/rh-osbs/${OMR_IMAGE_ENV}"
fi
OMR_RELEASED_TEST="${OMR_RELEASE}"
OMR_CI_NAME="omrprowci$RANDOM"

####################
# get vpc id and public subnet from disconnected AWS VPC
VpcId=$(cat "${SHARED_DIR}/vpc_id")
echo "VpcId: $VpcId"

PublicSubnet=$(cat "${SHARED_DIR}/public_subnet_ids" | yq '.[0]')
echo "PublicSubnet: $PublicSubnet"

# get AWS region
REGION="${LEASED_RESOURCE}"
echo "REGION: $REGION"
####################

cat >>omr-ami-images.json <<EOF
{
  "images": {
    "aws": {
      "regions": {
        "us-east-1": {
          "release": "RHEL_HA-8.4.0_HVM-20210504-x86_64-2-Hourly2-GP2",
          "image": "ami-02e0bb36c61bb9715"
        },
        "us-east-2": {
          "release": "RHEL_HA-8.4.0_HVM-20210504-x86_64-2-Hourly2-GP2",
          "image": "ami-0b2e47f3b2e23d235"
        },
        "us-west-1": {
          "release": "RHEL_HA-8.4.0_HVM-20210504-x86_64-2-Hourly2-GP2",
          "image": "ami-054965c6cd7c6e462"
        },
        "us-west-2": {
          "release": "RHEL_HA-8.4.0_HVM-20210504-x86_64-2-Hourly2-GP2",
          "image": "ami-0b28dfc7adc325ef4"
        },
        "ap-northeast-1": {
          "release": "RHEL_HA-8.4.0_HVM-20210504-x86_64-2-Hourly2-GP2",
          "image": "ami-0cf31bd68732fb0e2"
        },
        "ap-southeast-2": {
          "release": "RHEL_HA-8.4.0_HVM-20210504-x86_64-2-Hourly2-GP2",
          "image": "ami-016461ac55b16fd05"
        },
        "ap-northeast-3": {
          "release": "RHEL_HA-8.4.0_HVM-20210504-x86_64-2-Hourly2-GP2",
          "image": "ami-08daa4649f61b8684"
        },
        "ap-southeast-1": {
          "release": "RHEL_HA-8.4.0_HVM-20210504-x86_64-2-Hourly2-GP2",
          "image": "ami-0d6ba217f554f6137"
        },
        "ap-northeast-2": {
          "release": "RHEL_HA-8.4.0_HVM-20210504-x86_64-2-Hourly2-GP2",
          "image": "ami-0bb1758bf5a69ca5c"
        }
      }
    }
  }
}
EOF

ami_id=$(jq -r .images.aws.regions[\"${REGION}\"].image <omr-ami-images.json)

mkdir -p terraform_omr && cd terraform_omr

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
  region = "${REGION}"
  access_key = "${OMR_AWS_ACCESS_KEY}"
  secret_key = "${OMR_AWS_SECRET_KEY}"
}
resource "aws_key_pair" "quaybuilder0710" {
  key_name   = var.quay_build_worker_key
  public_key = file("./quaybuilder.pub")
}
resource "aws_security_group" "quaybuilder" {
  name        = var.quay_build_worker_security_group
  description = "Allow all inbound traffic"
  vpc_id      = "${VpcId}"
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
  ami           = "${ami_id}"
  instance_type = "m6i.2xlarge"
  associate_public_ip_address = true
  vpc_security_group_ids = [aws_security_group.quaybuilder.id]
  subnet_id = "${PublicSubnet}"

  root_block_device {
    volume_size = 200
  }
  provisioner "remote-exec" {
    inline = [
      "sudo yum install podman openssl -y",
      "podman login brew.registry.redhat.io -u '${OMR_BREW_USERNAME}' -p ${OMR_BREW_PASSWORD}",
      "echo ${OMR_IMAGE_TAG}",
      "echo ${OMR_RELEASED_TEST}",
      "if [ ${OMR_RELEASED_TEST} = false ]; then podman cp \$(podman create --rm ${OMR_IMAGE_TAG}):/mirror-registry.tar.gz .; fi",
      "if [ ${OMR_RELEASED_TEST} = true ]; then curl -L -o mirror-registry.tar.gz https://openshift-mirror-list.ci-systems.workers.dev/pub/cgw/mirror-registry/latest/mirror-registry-amd64.tar.gz --retry 12; fi",
      "tar -xzvf mirror-registry.tar.gz",
      "./mirror-registry --version",
      "./mirror-registry install --quayHostname \${aws_instance.quaybuilder.public_dns} --initPassword password --initUser quay -v"
    ]
  }
EOF

cat >>create_aws_ec2.tf <<'TFEOF'
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
TFEOF

cp /var/run/quay-qe-omr-secret/quaybuilder . && cp /var/run/quay-qe-omr-secret/quaybuilder.pub .
chmod 600 ./quaybuilder && chmod 600 ./quaybuilder.pub && echo "" >>quaybuilder

export TF_VAR_quay_build_instance_name="${OMR_CI_NAME}"
export TF_VAR_quay_build_worker_key="${OMR_CI_NAME}"
export TF_VAR_quay_build_worker_security_group="${OMR_CI_NAME}"
terraform init
terraform apply -auto-approve

#Share the OMR HOSTNAME, Terraform Var and Terraform Directory
tar -cvzf terraform.tgz --exclude=".terraform" *
cp terraform.tgz ${SHARED_DIR}

#Use Terraform to output the Public DNS Name of Quay OMR
OMR_HOST_NAME=$(terraform output instance_public_dns | tr -d '"')
echo "OMR HOST NAME is $OMR_HOST_NAME"

echo "${OMR_HOST_NAME}" >${SHARED_DIR}/OMR_HOST_NAME
echo "${OMR_CI_NAME}" >${SHARED_DIR}/OMR_CI_NAME

#Share the CA Cert of Quay OMR
scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/tmp/ssh_known_hosts -o VerifyHostKeyDNS=no -o ConnectionAttempts=3 -i quaybuilder ec2-user@"${OMR_HOST_NAME}":/home/ec2-user/quay-install/quay-rootCA/rootCA.pem ${SHARED_DIR} || true

#Test OMR by push image
skopeo copy docker://docker.io/fedora@sha256:895cdfba5eb6a009a26576cb2a8bc199823ca7158519e36e4d9effcc8b951b47 docker://"${OMR_HOST_NAME}":8443/quaytest/test:latest --dest-tls-verify=false --dest-creds quay:password || true
