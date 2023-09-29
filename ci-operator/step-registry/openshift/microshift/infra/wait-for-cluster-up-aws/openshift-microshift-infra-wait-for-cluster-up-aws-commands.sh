#!/bin/bash

set -xeuo pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

IP_ADDRESS="$(cat ${SHARED_DIR}/public_address)"
HOST_USER="$(cat ${SHARED_DIR}/ssh_user)"
INSTANCE_PREFIX="${HOST_USER}@${IP_ADDRESS}"

echo "Using Host $IP_ADDRESS"

mkdir -p "${HOME}/.ssh"
cat <<EOF >"${HOME}/.ssh/config"
Host ${IP_ADDRESS}
  User ${HOST_USER}
  IdentityFile ${CLUSTER_PROFILE_DIR}/ssh-privatekey
  StrictHostKeyChecking accept-new
  ServerAliveInterval 30
  ServerAliveCountMax 1200
EOF
chmod 0600 "${HOME}/.ssh/config"

cat > "${HOME}"/start_microshift.sh <<'EOF'
#!/bin/bash
set -xeuo pipefail

sudo systemctl enable microshift --now

# If condition is true there is podman, it's not a rpm install.
if [[ $(command -v podman) ]]; then
  # podman is present so copy the config file
  sudo mkdir -p /var/lib/microshift/resources/kubeadmin/
  sudo podman cp microshift:/var/lib/microshift/resources/kubeadmin/kubeconfig /var/lib/microshift/resources/kubeadmin/kubeconfig  
else
  echo "This is rpm run";
  # test if microshift is running
  sudo systemctl status microshift;

  # test if microshift created the kubeconfig under /var/lib/microshift/resources/kubeadmin/kubeconfig
  while ! sudo test -f "/var/lib/microshift/resources/kubeadmin/kubeconfig";
  do
    echo "Waiting for kubeconfig..."
    sleep 5;
  done
  sudo ls -la /var/lib/microshift
  sudo ls -la /var/lib/microshift/resources/kubeadmin/kubeconfig
fi
EOF

chmod +x "${HOME}"/start_microshift.sh

scp "${HOME}"/start_microshift.sh "${INSTANCE_PREFIX}":~/start_microshift.sh
ssh "${INSTANCE_PREFIX}" "/home/${HOST_USER}/start_microshift.sh"

ssh "${INSTANCE_PREFIX}" "sudo cat /var/lib/microshift/resources/kubeadmin/${IP_ADDRESS}/kubeconfig" > "${SHARED_DIR}/kubeconfig"

# Disable exit-on-error and enable command logging with a timestamp
set +e
set -x
PS4='+ $(date "+%T.%N")\011'

retries=3
while [ ${retries} -gt 0 ] ; do
  ((retries-=1))

  KUBECONFIG="${SHARED_DIR}/kubeconfig" oc wait \
    pod \
    --for=condition=ready \
    -l='app.kubernetes.io/name=topolvm-csi-driver' \
    -n openshift-storage \
    --timeout=5m
  [ $? -eq 0 ] && exit 0

  # Image pull operation sometimes get stuck for topolvm images
  # Delete topolvm pods to retry image pull operation
  KUBECONFIG="${SHARED_DIR}/kubeconfig" oc delete \
    pod \
    -l='app.kubernetes.io/name=topolvm-csi-driver' \
    -n openshift-storage \
    --timeout=30s
done

# All retries waiting for the cluster failed
exit 1
