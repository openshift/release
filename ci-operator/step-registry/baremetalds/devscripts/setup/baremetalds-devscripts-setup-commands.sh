#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds devscripts setup command ************"

# Fetch packet basic configuration
# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

# Get dev-scripts logs and other configuration
finished()
{
  # Remember dev-scripts setup exit code
  retval=$?

  echo "Fetching kubeconfig, other credentials..."
  scp "${SSHOPTS[@]}" "root@${IP}:/root/dev-scripts/ocp/*/auth/kubeconfig" "${SHARED_DIR}/"
  scp "${SSHOPTS[@]}" "root@${IP}:/root/dev-scripts/ocp/*/auth/kubeadmin-password" "${SHARED_DIR}/"

  echo "Adding proxy-url in kubeconfig"
  sed -i "/- cluster/ a\    proxy-url: http://$IP:8213/" "${SHARED_DIR}"/kubeconfig

  # Get dev-scripts logs
  echo "dev-scripts setup completed, fetching logs"
  ssh "${SSHOPTS[@]}" "root@${IP}" tar -czf - /root/dev-scripts/logs | tar -C "${ARTIFACT_DIR}" -xzf -
  echo "Removing REDACTED info from log..."
  sed -i '
    s/.*auths.*/*** PULL_SECRET ***/g;
    s/password: .*/password: REDACTED/;
    s/X-Auth-Token.*/X-Auth-Token REDACTED/;
    s/UserData:.*,/UserData: REDACTED,/;
    ' "${ARTIFACT_DIR}"/root/dev-scripts/logs/*

  # Save exit code for must-gather to generate junit. Make eats exit
  # codes, so we try to fetch it from the dev-scripts artifacts if we can.
  status_file=${ARTIFACT_DIR}/root/dev-scripts/logs/installer-status.txt
  if [ -f "$status_file"  ];
  then
    cp "$status_file" "${SHARED_DIR}/install-status.txt"
  else
    echo "$retval" > "${SHARED_DIR}/install-status.txt"
  fi
}
trap finished EXIT TERM

# Make sure this host hasn't been previously used
ssh "${SSHOPTS[@]}" "root@${IP}" mkdir /root/nodesfirstuse

# Copy dev-scripts source from current directory to the remote server
tar -czf - . | ssh "${SSHOPTS[@]}" "root@${IP}" "cat > /root/dev-scripts.tar.gz"

# Prepare configuration and run dev-scripts
scp "${SSHOPTS[@]}" "${CLUSTER_PROFILE_DIR}/pull-secret" "root@${IP}:pull-secret"

# Additional mechanism to inject dev-scripts additional variables directly
# from a multistage step configuration.
# Backward compatible with the previous approach based on creating the
# dev-scripts-additional-config file from a multistage step command
if [[ -n "${DEVSCRIPTS_CONFIG:-}" ]]; then
  readarray -t config <<< "${DEVSCRIPTS_CONFIG}"
  for var in "${config[@]}"; do
    if [[ ! -z "${var}" ]]; then
      echo "export ${var}" >> "${SHARED_DIR}/dev-scripts-additional-config"
    fi
  done
fi

# Copy additional dev-script configuration provided by the the job, if present
if [[ -e "${SHARED_DIR}/dev-scripts-additional-config" ]]
then
  scp "${SSHOPTS[@]}" "${SHARED_DIR}/dev-scripts-additional-config" "root@${IP}:dev-scripts-additional-config"
fi

[ -e "${SHARED_DIR}/bm.json" ] && scp "${SSHOPTS[@]}" "${SHARED_DIR}/bm.json" "root@${IP}:bm.json"


timeout -s 9 175m ssh "${SSHOPTS[@]}" "root@${IP}" bash - << EOF |& sed -e 's/.*auths.*/*** PULL_SECRET ***/g'

set -xeuo pipefail

# Some Packet images have a file /usr/config left from the provisioning phase.
# The problem is that sos expects it to be a directory. Since we don't care
# about the Packet provisioner, remove the file if it's present.
test -f /usr/config && rm -f /usr/config || true

# TODO: remove this once rocky is marked as supported in dev-scripts
sed -i -e 's/rocky/centos/g; s/Rocky/CentOS/g' /etc/os-release

yum install -y git sysstat sos make
systemctl start sysstat

mkdir -p /tmp/artifacts

mkdir dev-scripts
tar -xzvf dev-scripts.tar.gz -C /root/dev-scripts
chown -R root:root dev-scripts

NVME_DEVICE="/dev/nvme0n1"
if [ -e "\$NVME_DEVICE" ];
then
  mkfs.xfs -f "\${NVME_DEVICE}"
  mkdir /opt/dev-scripts
  mount "\${NVME_DEVICE}" /opt/dev-scripts
fi

cd dev-scripts

cp /root/pull-secret /root/dev-scripts/pull_secret.json

echo "export OPENSHIFT_RELEASE_IMAGE=${OPENSHIFT_INSTALL_RELEASE_IMAGE}" >> /root/dev-scripts/config_root.sh
echo "export ADDN_DNS=\$(awk '/nameserver/ { print \$2;exit; }' /etc/resolv.conf)" >> /root/dev-scripts/config_root.sh
echo "export OPENSHIFT_CI=true" >> /root/dev-scripts/config_root.sh
echo "export NUM_WORKERS=3" >> /root/dev-scripts/config_root.sh
echo "export WORKER_MEMORY=16384" >> /root/dev-scripts/config_root.sh
echo "export ENABLE_LOCAL_REGISTRY=true" >> /root/dev-scripts/config_root.sh

# Inject PR additional configuration, if available
if [[ -e /root/dev-scripts/dev-scripts-additional-config ]]
then
  cat /root/dev-scripts/dev-scripts-additional-config >> /root/dev-scripts/config_root.sh
# Inject job additional configuration, if available
elif [[ -e /root/dev-scripts-additional-config ]]
then
  cat /root/dev-scripts-additional-config >> /root/dev-scripts/config_root.sh
fi

if [ -e /root/bm.json ] ; then
    . /root/dev-scripts-additional-config

    cp /root/bm.json /root/dev-scripts/bm.json

    nmcli --fields UUID c show | grep -v UUID | xargs -t -n 1 nmcli con delete
    nmcli con add ifname \${CLUSTER_NAME}bm type bridge con-name \${CLUSTER_NAME}bm bridge.stp off
    nmcli con add type ethernet ifname eth2 master \${CLUSTER_NAME}bm con-name \${CLUSTER_NAME}bm-eth2
    nmcli con reload
    sleep 10

    echo 'export KUBECONFIG=/root/dev-scripts/ocp/\$CLUSTER_NAME/auth/kubeconfig' >> /root/.bashrc
else
    echo 'export KUBECONFIG=/root/dev-scripts/ocp/ostest/auth/kubeconfig' >> /root/.bashrc
fi

timeout -s 9 105m make ${DEVSCRIPTS_TARGET}

if [ -e /root/bm.json ] ; then
    sudo firewall-cmd --add-port=8213/tcp --zone=libvirt
fi
EOF

# Copy dev-scripts variables to be shared with the test step
ssh "${SSHOPTS[@]}" "root@${IP}" bash - << EOF |& sed -e 's/.*auths.*/*** PULL_SECRET ***/g'
cd /root/dev-scripts
source common.sh
source ocp_install_env.sh

set +x
echo "export DS_OPENSHIFT_VERSION=\$(openshift_version)" >> /tmp/ds-vars.conf
echo "export DS_REGISTRY=\$LOCAL_REGISTRY_DNS_NAME:\$LOCAL_REGISTRY_PORT" >> /tmp/ds-vars.conf
echo "export DS_WORKING_DIR=\$WORKING_DIR" >> /tmp/ds-vars.conf
echo "export DS_IP_STACK=\$IP_STACK" >> /tmp/ds-vars.conf
EOF

scp "${SSHOPTS[@]}" "root@${IP}:/tmp/ds-vars.conf" "${SHARED_DIR}/"


# Add required configurations ci-chat-bot need
ssh "${SSHOPTS[@]}" "root@${IP}" bash - << EOF |& sed -e 's/.*auths.*/*** PULL_SECRET ***/g'
echo "https://\$(oc -n openshift-console get routes console -o=jsonpath='{.spec.host}')" > /tmp/console.url
EOF

# Save console URL in `console.url` file so that ci-chat-bot could report success
scp "${SSHOPTS[@]}" "root@${IP}:/tmp/console.url" "${SHARED_DIR}/"
