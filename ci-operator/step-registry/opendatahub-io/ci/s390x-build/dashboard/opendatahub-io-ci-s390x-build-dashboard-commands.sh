#!/bin/bash

set -ex

# Session variables
zvsi_fip=$(cat "${SHARED_DIR}/zvsi_fip")
ssh_key_string=$(cat "${AGENT_IBMZ_CREDENTIALS}/httpd-vsi-key")
export ssh_key_string
tmp_ssh_key="/tmp/httpd-vsi-key"
envsubst <<"EOF" >${tmp_ssh_key}
-----BEGIN OPENSSH PRIVATE KEY-----
${ssh_key_string}

-----END OPENSSH PRIVATE KEY-----
EOF
chmod 0600 ${tmp_ssh_key}
ssh_options=(-o 'PreferredAuthentications=publickey' -o 'StrictHostKeyChecking=no' -o 'UserKnownHostsFile=/dev/null' -o 'ServerAliveInterval=60' -i "$tmp_ssh_key")

# Get current date
current_date=$(date +%F)
echo "Current date is $current_date"

# Get IMAGE_TAG if not provided
if [[ -z "$IMAGE_TAG" ]]; then
    case "$JOB_TYPE" in
        presubmit)
            echo "Building default image tag for a $JOB_TYPE job"
            IMAGE_TAG="pr-${PULL_NUMBER}"
            if [[ -n "${RELEASE_VERSION-}" ]]; then
                IMAGE_TAG="${RELEASE_VERSION}-${IMAGE_TAG}"
            fi
            ;;
        postsubmit)
            echo "Building default image tag for a $JOB_TYPE job"
            IMAGE_TAG="${RELEASE_VERSION}-${PULL_BASE_SHA:0:7}"
            ;;
        periodic)
            echo "Building default image tag for a $JOB_TYPE job"
            IMAGE_TAG="${RELEASE_VERSION}-nightly-${current_date}"
            IMAGE_FLOATING_TAG="${RELEASE_VERSION}-${YEAR_INDEX}"
            ;;
        *)
            echo "ERROR Cannot publish an image from a $JOB_TYPE job"
            exit 1
            ;;
    esac
fi

# Get IMAGE_TAG if it's equal to YearIndex in YYYYMMDD format
if [[ "$IMAGE_TAG" == "YearIndex" ]]; then
    YEAR_INDEX=$(echo "$(date +%Y%m%d)")
    case "$JOB_TYPE" in
        presubmit)
            echo "Building YearIndex image tag for a $JOB_TYPE job"
            IMAGE_TAG="pr-${PULL_NUMBER}"
            if [[ -n "${RELEASE_VERSION-}" ]]; then
                IMAGE_TAG="${RELEASE_VERSION}-${IMAGE_TAG}"
            fi
            ;;
        postsubmit)
            echo "Building YearIndex image tag for a $JOB_TYPE job"
            IMAGE_TAG="${RELEASE_VERSION}-${YEAR_INDEX}-${PULL_BASE_SHA:0:7}"
            IMAGE_FLOATING_TAG="${RELEASE_VERSION}-${YEAR_INDEX}"
            ;;
        periodic)
            echo "Building weekly image tag for a $JOB_TYPE job"
            IMAGE_TAG="${RELEASE_VERSION}-weekly"
            ;;
        *)
            echo "ERROR Cannot publish an image from a $JOB_TYPE job"
            exit 1
            ;;
    esac
fi

# Build destination image reference
DESTINATION_REGISTRY_REPO="$REGISTRY_HOST/$REGISTRY_ORG/$IMAGE_REPO"
DESTINATION_IMAGE_REF="$DESTINATION_REGISTRY_REPO:$IMAGE_TAG"
if [[ -n "${IMAGE_FLOATING_TAG-}" ]]; then
    FLOATING_IMAGE_REF="$DESTINATION_REGISTRY_REPO:$IMAGE_FLOATING_TAG"
    DESTINATION_IMAGE_REF="$DESTINATION_IMAGE_REF $FLOATING_IMAGE_REF"
fi

echo "Image is $DESTINATION_IMAGE_REF"
echo "JOB SPECS are $JOB_SPEC"
echo "FIP of VM is $zvsi_fip"

# Get credentials for quay repo
DOCKER_USER=$(cat "${SECRETS_PATH}/$REGISTRY_SECRET/${REGISTRY_SECRET_FILE}" | jq -r ".auths[\"${REGISTRY_HOST}\"].auth" | base64 -d | cut -d':' -f1)
export DOCKER_USER
echo "docker user is $DOCKER_USER"
DOCKER_PASS=$(cat "${SECRETS_PATH}/$REGISTRY_SECRET/${REGISTRY_SECRET_FILE}" | jq -r ".auths[\"${REGISTRY_HOST}\"].auth" | base64 -d | cut -d':' -f2)
export DOCKER_PASS

# Initialize ALL_VARS as an array of variable assignments
ALL_VARS=("DESTINATION_IMAGE_REF='$DESTINATION_IMAGE_REF' SECRETS_PATH='$SECRETS_PATH' REGISTRY_SECRET_FILE='$REGISTRY_SECRET_FILE' REGISTRY_HOST='$REGISTRY_HOST' DOCKER_USER='$DOCKER_USER' DOCKER_PASS='$DOCKER_PASS' PLATFORMS='$PLATFORMS'")
ALL_VARS_STR=$(IFS=" "; echo "${ALL_VARS[*]}")
export ALL_VARS_STR

# create ssh session to zvsi and pass the script
ssh "${ssh_options[@]}" root@"$zvsi_fip" "$ALL_VARS_STR bash -s" << 'EOF'
#Installing docker in zvsi
echo "Installing docker engine in zvsi"

# Add Docker's official GPG key:
apt-get update
apt-get install ca-certificates curl -y
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

# Add the repository to Apt sources:
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
apt-get update
apt-get install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin -y

echo "Platforms is $PLATFORMS "
echo "Image tag is $IMAGE_TAG "
git clone https://github.com/opendatahub-io/odh-dashboard

#we don't need to change branch for nightly builds
#git checkout $PULL_BASE_SHA

cd odh-dashboard

# Enable Buildx and Quemu for multiarch builds
docker run --rm --privileged multiarch/qemu-user-static --reset -p yes
docker buildx create --platform="${PLATFORMS}" --name mybuilder --use
docker buildx inspect --bootstrap

# Log in to the registry
docker login -u "${DOCKER_USER}" -p "${DOCKER_PASS}" "${REGISTRY_HOST}"

# Build and push the multiarch image
echo "pushing image $DESTINATION_IMAGE_REF "
docker buildx build --platform "${PLATFORMS}" \
                    -t "$DESTINATION_IMAGE_REF" \
                    --push .

if [ $? -eq 0 ]; then
    echo "Build and publish has been successful for multiarch image $DESTINATION_IMAGE_REF "
else
    echo "Build and publish failed for multiarch image $DESTINATION_IMAGE_REF "
fi
EOF
