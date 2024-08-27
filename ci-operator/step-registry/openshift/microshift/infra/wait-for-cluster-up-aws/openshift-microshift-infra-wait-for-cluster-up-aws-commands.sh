#!/bin/bash
set -xeuo pipefail

# shellcheck disable=SC1091
source "${SHARED_DIR}/ci-functions.sh"
ci_script_prologue
trap_subprocesses_on_term

trap 'finalize' EXIT TERM INT

# Look at sos step for the exit codes definitions
function finalize()
{
  if [[ "$?" -ne "0" ]] ; then
    echo "9" >> "${SHARED_DIR}/install-status.txt"
  else
    echo "0" >> "${SHARED_DIR}/install-status.txt"
  fi
}

cat > "${HOME}"/start_microshift.sh <<'EOF'
#!/bin/bash
set -xeuo pipefail

sudo systemctl enable microshift --now
sudo systemctl status microshift

while ! sudo test -f "/var/lib/microshift/resources/kubeadmin/kubeconfig";
do
  echo "Waiting for kubeconfig..."
  sleep 5;
done
sudo ls -la /var/lib/microshift/resources/kubeadmin/
sudo systemctl restart greenboot-healthcheck

EOF

chmod +x "${HOME}"/start_microshift.sh

scp "${HOME}"/start_microshift.sh "${INSTANCE_PREFIX}":~/start_microshift.sh
ssh "${INSTANCE_PREFIX}" "/home/${HOST_USER}/start_microshift.sh"

ssh "${INSTANCE_PREFIX}" "sudo cat /var/lib/microshift/resources/kubeadmin/${IP_ADDRESS}/kubeconfig" > "${SHARED_DIR}/kubeconfig"

# Disable exit-on-error
set +e

retries=10
while [ ${retries} -gt 0 ] ; do
  ((retries-=1))
  if ssh "${INSTANCE_PREFIX}" "sudo systemctl status greenboot-healthcheck | grep -q 'active (exited)'"; then
    exit 0
  fi
  echo "Not ready yet. Waiting 30 seconds... (${retries} retries remaining)"
  sleep 30
done

# All retries waiting for the cluster failed
exit 1
