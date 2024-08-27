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
    echo "5" >> "${SHARED_DIR}/install-status.txt"
  else
    echo "0" >> "${SHARED_DIR}/install-status.txt"
  fi
}

cat << EOF > /tmp/config.yaml
apiServer:
  subjectAltNames:
  - ${IP_ADDRESS}
EOF

configure_vm_args=""
if "${OPTIONAL_RPMS}"; then
  configure_vm_args="--optional-rpms"
fi

cat <<EOF > /tmp/install.sh
#!/bin/bash
set -xeuo pipefail

source /tmp/ci-functions.sh
ci_subscription_register

sudo mkdir -p /etc/microshift
sudo mv /tmp/config.yaml /etc/microshift/config.yaml
tar -xf /tmp/microshift.tgz -C ~ --strip-components 4
cd ~/microshift
./scripts/devenv-builder/configure-vm.sh --force-firewall --pull-images ${configure_vm_args} /tmp/pull-secret
EOF
chmod +x /tmp/install.sh

tar czf /tmp/microshift.tgz /go/src/github.com/openshift/microshift

scp \
  "${SHARED_DIR}/ci-functions.sh" \
  /tmp/install.sh \
  /var/run/rhsm/subscription-manager-org \
  /var/run/rhsm/subscription-manager-act-key \
  "${CLUSTER_PROFILE_DIR}/pull-secret" \
  /tmp/microshift.tgz \
  /tmp/config.yaml \
  "${INSTANCE_PREFIX}:/tmp"

ssh "${INSTANCE_PREFIX}" "/tmp/install.sh"
