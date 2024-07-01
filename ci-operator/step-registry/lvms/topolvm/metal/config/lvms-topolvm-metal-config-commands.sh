#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
export PS4='+ $(date "+%T.%N") \011'

SSHOPTS=(-o 'ConnectTimeout=5'
  -o 'StrictHostKeyChecking=no'
  -o 'UserKnownHostsFile=/dev/null'
  -o 'ServerAliveInterval=90'
  -o LogLevel=ERROR
  -i "${CLUSTER_PROFILE_DIR}/ssh-privatekey")

instance_ip=$(cat ${SHARED_DIR}/public_address)
host=$(cat ${SHARED_DIR}/ssh_user)

ssh_host_ip="$host@$instance_ip"

if ! test -f "${SHARED_DIR}/remote_workdir"; then
  workdir="/home/${host}/workdir-$(date +%Y%m%d)"

  echo "${workdir}" >> "${SHARED_DIR}/remote_workdir"
fi

remote_workdir=$(cat "${SHARED_DIR}/remote_workdir")

ssh "${SSHOPTS[@]}" "${ssh_host_ip}" "mkdir -p ${remote_workdir}"

cat <<EOF > ${SHARED_DIR}/install.sh
#!/bin/bash
set -euo pipefail

cd ${remote_workdir}

curl -LO https://go.dev/dl/${GO_VERSION}.tar.gz

# Verify the checksum
if echo "${GO_CHECKSUM} ${GO_VERSION}.tar.gz" | sha256sum -c -; then
    echo "Checksum verification succeeded."

    # Remove any existing Go installation in the remote working directory
    rm -rf ${remote_workdir}/go

    # Extract the Go tarball
    tar -C ${remote_workdir} -xzf ${GO_VERSION}.tar.gz

    # Clean up the tarball
    rm ${GO_VERSION}.tar.gz

    # Add Go binary to PATH
    echo 'export PATH=$PATH:${remote_workdir}/go/bin' >> ~/.profile && source ~/.profile
else
    echo "Go Checksum verification failed (${GO_VERSION} was expected to match ${GO_CHECKSUM})!"
    # Clean up the downloaded file
    rm ${GO_VERSION}.tar.gz
    exit 1
fi

sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo \
  "deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  \$(. /etc/os-release && echo "\$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update

sudo apt-get install \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin \
    ca-certificates \
    curl \
    lvm2 \
    util-linux \
    make \
    -y

sudo usermod -aG docker ubuntu
newgrp docker

PULL_NUMBER=${PULL_NUMBER:-}


# Check if PULL_NUMBER environment variable is set and not empty
# if the repo is openshift/release, we have a PR during testing but it will be for openshift/release,
# so also fallback to main branch in that case.
if [ -z "\${PULL_NUMBER}" ] || [ "${REPO_OWNER}/${REPO_NAME}" == "openshift/release" ]; then
    echo "PULL_NUMBER is not set or pj-rehearse detected. Defaulting to the 'main' branch of 'openshift/topolvm'."

    # Clone the repository and checkout the 'main' branch
    rm -rf topolvm
    git clone -b main --single-branch https://github.com/openshift/topolvm
else
    echo "PULL_NUMBER is set to '\${PULL_NUMBER}'. Checking out the pull request."

    # Clone the repository and fetch the pull request branch
    rm -rf topolvm
    git clone https://github.com/${REPO_OWNER}/${REPO_NAME} topolvm
    pushd topolvm
    git fetch origin pull/\${PULL_NUMBER}/head:\${PULL_NUMBER}
    git checkout \${PULL_NUMBER}
fi

EOF

chmod +x ${SHARED_DIR}/install.sh
scp "${SSHOPTS[@]}" ${SHARED_DIR}/install.sh $ssh_host_ip:$remote_workdir

ssh "${SSHOPTS[@]}" $ssh_host_ip "${remote_workdir}/install.sh"