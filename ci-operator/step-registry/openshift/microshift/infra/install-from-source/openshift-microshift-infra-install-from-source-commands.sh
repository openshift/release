#!/bin/bash
set -xeuo pipefail

# shellcheck disable=SC1091
source "${SHARED_DIR}/ci-functions.sh"
ci_script_prologue
trap_subprocesses_on_term

cat << EOF2 > /tmp/config.yaml
apiServer:
  subjectAltNames:
  - ${IP_ADDRESS}
EOF2

cat <<'EOF' > /tmp/install.sh
#!/bin/bash
set -xeuo pipefail

source /tmp/ci-functions.sh
ci_subscription_register
download_microshift_scripts

sudo mkdir -p /etc/microshift
sudo cp /tmp/config.yaml /etc/microshift/config.yaml

hash git || "${DNF_RETRY}" "install" "git-core"
git clone https://github.com/openshift/microshift -b ${BRANCH} ${HOME}/microshift

cd ${HOME}/microshift
chmod 0755 ${HOME}
bash -x ./scripts/devenv-builder/configure-vm.sh --force-firewall /tmp/pull-secret
EOF
chmod +x /tmp/install.sh

scp \
  "${SHARED_DIR}/ci-functions.sh" \
  /tmp/install.sh \
  /tmp/config.yaml \
  /var/run/rhsm/subscription-manager-org \
  /var/run/rhsm/subscription-manager-act-key \
  "${CLUSTER_PROFILE_DIR}/pull-secret" \
  "${INSTANCE_PREFIX}:/tmp"

# shellcheck disable=SC2029
ssh "${INSTANCE_PREFIX}" "BRANCH=${BRANCH} /tmp/install.sh"
