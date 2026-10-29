#!/bin/bash
set -xeuo pipefail

# shellcheck disable=SC1091
source "${SHARED_DIR}/ci-functions.sh"
ci_script_prologue
trap_subprocesses_on_term
trap_install_status_exit_code $EXIT_CODE_WAIT_CLUSTER_FAILURE

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
# Trigger greenboot health checks. On greenboot-rs (RHEL 9.8+) manual
# restart is refused, so suppress the error — the polling loop handles it.
sudo systemctl restart greenboot-healthcheck 2>/dev/null || true
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
  if ssh "${INSTANCE_PREFIX}" "sudo microshift healthcheck --timeout 30s 2>/dev/null"; then
    exit 0
  fi
  echo "Not ready yet. Waiting 30 seconds... (${retries} retries remaining)"
  sleep 30
done

# All retries waiting for the cluster failed
exit 1
