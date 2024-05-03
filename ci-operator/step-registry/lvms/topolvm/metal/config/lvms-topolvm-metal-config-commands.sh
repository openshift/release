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
rm -rf ${remote_workdir}/go
tar -C ${remote_workdir} -xzf ${GO_VERSION}.tar.gz
rm ${GO_VERSION}.tar.gz
echo 'export PATH=$PATH:${remote_workdir}/go/bin' >> ~/.profile && source ~/.profile

sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo \
  "deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "\$VERSION_CODENAME") stable" | \
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
    -y

sudo groupadd docker
sudo usermod -aG docker ubuntu
newgrp docker





git clone github.com/topolvm/topolvm@${PULL_PULL_SHA} topolvm

EOF

chmod +x ${SHARED_DIR}/install.sh
scp "${SSHOPTS[@]}" ${SHARED_DIR}/install.sh $ssh_host_ip:$remote_workdir

ssh "${SSHOPTS[@]}" $ssh_host_ip "${remote_workdir}/install.sh"