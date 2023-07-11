#!/usr/bin/env bash
set -xeuo pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

IP_ADDRESS="$(cat "${SHARED_DIR}"/public_address)"
HOST_USER="$(cat "${SHARED_DIR}"/ssh_user)"
INSTANCE_PREFIX="${HOST_USER}@${IP_ADDRESS}"

echo "Using Host $IP_ADDRESS"

mkdir -p "${HOME}/.ssh"
cat <<EOF >"${HOME}/.ssh/config"
Host ${IP_ADDRESS}
  IdentityFile ${CLUSTER_PROFILE_DIR}/ssh-privatekey
  StrictHostKeyChecking accept-new
  ServerAliveInterval 30
  ServerAliveCountMax 1200
EOF
chmod 0600 "${HOME}/.ssh/config"

# Print test output on exit
print_test_output() {
  echo "##### START TEST OUTPUT #####"

  for log in /tmp/run_*_test.log ; do
    echo "##### OUTPUT OF ${log} TEST #####"
    cat "${log}"
  done

  echo "##### FINISH TEST OUTPUT #####"
}

# Bash e2e tests
run_e2e() {
  local -r VM_IP="${IP_ADDRESS}"
  local -r VM_PORT="$(cat "${SHARED_DIR}"/vm_ssh_port_0)"
  local -r VM_USER="$(cat "${SHARED_DIR}"/vm_user_0)"

  cat << EOF >/tmp/e2e.yaml
USHIFT_HOST: ${VM_IP}
USHIFT_USER: ${VM_USER}
SSH_PRIV_KEY: ${CLUSTER_PROFILE_DIR}/ssh-privatekey
SSH_PORT: ${VM_PORT}
EOF
  /microshift/test/run.sh -o "${ARTIFACT_DIR}/e2e" -i /tmp/e2e.yaml -v /tmp/venv /microshift/test/suites-ostree/backup-restore.robot
}

# Bash CNCF Tests
# See https://github.com/openshift/microshift/blob/main/docs/multinode/setup.md
run_cncf() {
  local -r PRI_HOST="$(cat "${SHARED_DIR}"/vm_ssh_host_1)"
  local -r PRI_ADDR="$(cat "${SHARED_DIR}"/vm_int_ip_1)"
  local -r PRI_PORT="$(cat "${SHARED_DIR}"/vm_ssh_port_1)"
  local -r PRI_USER="$(cat "${SHARED_DIR}"/vm_user_1)"

  local -r SEC_HOST="$(cat "${SHARED_DIR}"/vm_ssh_host_2)"
  local -r SEC_ADDR="$(cat "${SHARED_DIR}"/vm_int_ip_2)"
  local -r SEC_PORT="$(cat "${SHARED_DIR}"/vm_ssh_port_2)"
  local -r SEC_USER="$(cat "${SHARED_DIR}"/vm_user_2)"

  local -r SSH_CMD="ssh -i ${CLUSTER_PROFILE_DIR}/ssh-privatekey"
  local -r SCP_CMD="scp -i ${CLUSTER_PROFILE_DIR}/ssh-privatekey"

  local -r RUN_SCRIPT=/tmp/run_cncf.sh
  local -r KUBECONFIG=/tmp/kubeconfig-cncf

  cd /microshift/
  # Configure the primary host
  ${SCP_CMD} -P "${PRI_PORT}" ./scripts/multinode/configure-pri.sh "${PRI_USER}@${IP_ADDRESS}:"
  ${SSH_CMD} -p "${PRI_PORT}" "${PRI_USER}@${IP_ADDRESS}" \
    ./configure-pri.sh "${PRI_HOST}" "${PRI_ADDR}" "${SEC_HOST}" "${SEC_ADDR}"

  # Copy the kubelet configuration from the primary to the secondary host in two steps
  ${SCP_CMD} -P "${PRI_PORT}" \
    "${PRI_USER}@${IP_ADDRESS}:/home/redhat/kubelet-${SEC_HOST}".{key,crt} \
    "${PRI_USER}@${IP_ADDRESS}:/home/redhat/kubeconfig-${PRI_HOST}" \
    /tmp/
  ${SCP_CMD} -P "${SEC_PORT}" \
    "/tmp/kubelet-${SEC_HOST}".{key,crt} \
    "/tmp/kubeconfig-${PRI_HOST}" \
    "${SEC_USER}@${IP_ADDRESS}":

  # Configure the secondary host
  ${SCP_CMD} -P "${SEC_PORT}" ./scripts/multinode/configure-sec.sh "${SEC_USER}@${IP_ADDRESS}:"
  ${SSH_CMD} -p "${SEC_PORT}" "${SEC_USER}@${IP_ADDRESS}" \
    ./configure-sec.sh "${PRI_HOST}" "${PRI_ADDR}" "${SEC_HOST}" "${SEC_ADDR}"

  cat <<EOF > "${RUN_SCRIPT}"
#!/bin/bash
set -xeuo pipefail

cd \${HOME}/microshift

# Resolve primary host name locally
echo "${PRI_ADDR} ${PRI_HOST}" | sudo tee -a /etc/hosts &>/dev/null

export KUBECONFIG="${KUBECONFIG}"
oc get pods -A -o wide

# Wait up to 5m until both nodes are ready
NREADY=1
for _ in \$(seq 1 30) ; do
  NREADY=\$(oc get nodes --no-headers | awk '\$2=="Ready" {print \$1}' | wc -l)
  [ "\${NREADY}" = 2 ] && break
  sleep 10
done
oc get nodes -o wide
[ "\${NREADY}" != 2 ] && exit 1

# Configure cluster prerequisites
oc adm policy add-scc-to-group privileged system:authenticated system:serviceaccounts
oc adm policy add-scc-to-group anyuid     system:authenticated system:serviceaccounts

# Install the tests
sudo dnf install -y golang
go install github.com/vmware-tanzu/sonobuoy@latest

# Run the tests
~/go/bin/sonobuoy run \
    --mode=certified-conformance \
    --dns-namespace=openshift-dns \
    --dns-pod-labels=dns.operator.openshift.io/daemonset-dns=default

# Wait for up to 1m until tests start
WAIT_FAILURE=true
for _ in \$(seq 1 30) ; do
  if ~/go/bin/sonobuoy status --json | jq '.status' &>/dev/null ; then
    WAIT_FAILURE=false
    break
  fi
  sleep 2
done

# Exit with error on wait failure
\$WAIT_FAILURE && exit 1

# Wait until test complete (exit as soon as one of the tests failed)
TEST_FAILURE=false
while [ "\$(~/go/bin/sonobuoy status --json | jq -r '.status')" = "running" ] ; do
  ~/go/bin/sonobuoy status --json | jq '.plugins[] | select(.plugin=="e2e") | .progress'
  if [ "\$(~/go/bin/sonobuoy status --json | jq -r '.plugins[] | select(.plugin=="e2e") | .progress.failed')" != "null" ] ; then
    TEST_FAILURE=true
    break
  fi
  sleep 60
done

# Exit with error on test failure
\$TEST_FAILURE && exit 1
# Normal exit
exit 0
EOF

  # Download the kubeconfig from the primary host
  ${SCP_CMD} -P "${PRI_PORT}" "${PRI_USER}@${IP_ADDRESS}:/home/redhat/kubeconfig-${PRI_HOST}" "${KUBECONFIG}"
  cat "${KUBECONFIG}"

  # Copy and run the script, waiting up to 2h for it to complete
  chmod +x "${RUN_SCRIPT}"
  scp "${RUN_SCRIPT}" "${KUBECONFIG}" "${INSTANCE_PREFIX}:/tmp"
  timeout 120m ssh "${INSTANCE_PREFIX}" "${RUN_SCRIPT}"
}

######################################################################
# If more tests are to be run in parallel the code should go in here #
######################################################################

trap 'scp -r ${INSTANCE_PREFIX}:/home/${HOST_USER}/microshift/_output/test-images/scenario-info ${ARTIFACT_DIR}' EXIT

# Run the scenario tests, if the phase script exists
# (we can clean this up after the main PR lands)
cd /microshift/test || true
if [ -f ./bin/ci_phase_test.sh ]; then
    ./bin/ci_phase_test.sh
fi
