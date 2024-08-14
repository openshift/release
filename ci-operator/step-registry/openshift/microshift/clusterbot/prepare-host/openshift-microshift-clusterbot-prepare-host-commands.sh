#!/bin/bash
set -xeuo pipefail
export PS4='+ $(date "+%T.%N") \011'

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

IP_ADDRESS="$(cat "${SHARED_DIR}"/public_address)"
HOST_USER="$(cat "${SHARED_DIR}"/ssh_user)"
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

cat <<EOF >/tmp/config.yaml
apiServer:
  subjectAltNames:
  - ${IP_ADDRESS}
EOF

MICROSHIFT_CLUSTERBOT_SETTINGS="${SHARED_DIR}/microshift-clusterbot-settings"

cat <<'EOF' >/tmp/install.sh
#!/bin/bash
set -xeuo pipefail
export PS4='+ $(date "+%T.%N") ${BASH_SOURCE#$HOME/}:$LINENO \011'

enable_mirror_repo() {
    local -r url="${1}"
    sudo tee "/etc/yum.repos.d/microshift-mirror.repo" >/dev/null <<2EOF2
[microshift-mirror]
name=MicroShift mirror repository
baseurl=${url}
enabled=1
gpgcheck=0
skip_if_unavailable=0
2EOF2
}

DNF_RETRY=$(mktemp /tmp/dnf_retry.XXXXXXXX.sh)
curl -s https://raw.githubusercontent.com/openshift/microshift/main/scripts/dnf_retry.sh -o "${DNF_RETRY}"
chmod 755 "${DNF_RETRY}"

source /tmp/microshift-clusterbot-settings

if ! sudo subscription-manager status >&/dev/null; then
    sudo subscription-manager register \
        --org="$(cat /tmp/subscription-manager-org)" \
        --activationkey="$(cat /tmp/subscription-manager-act-key)"
fi

hash git || "${DNF_RETRY}" "install" "git-core"

sudo mkdir -p /etc/microshift
sudo cp /tmp/config.yaml /etc/microshift/config.yaml

if [[ -n "${MICROSHIFT_PR}" ]]; then
    git init ~/microshift
    cd ~/microshift
    git remote add origin https://github.com/openshift/microshift

    branch="pr-${MICROSHIFT_PR}"
    git fetch --no-tags origin "pull/${MICROSHIFT_PR}/head:${branch}"
    git switch "${branch}"

    configure_args=""
    if grep -qw -- "--skip-dnf-update" ~/microshift/scripts/devenv-builder/configure-vm.sh; then
        configure_args="--skip-dnf-update"
    fi
    bash -x ~/microshift/scripts/devenv-builder/configure-vm.sh --force-firewall ${configure_args} /tmp/pull-secret

elif [[ -n "${MICROSHIFT_GIT}" ]]; then
    : MICROSHIFT_GIT is set - clone it, build it, run it

    git clone https://github.com/openshift/microshift -b "${MICROSHIFT_GIT}" ~/microshift

    configure_args=""
    if grep -qw -- "--skip-dnf-update" ~/microshift/scripts/devenv-builder/configure-vm.sh; then
        configure_args="--skip-dnf-update"
    fi
    bash -x ~/microshift/scripts/devenv-builder/configure-vm.sh --force-firewall ${configure_args} /tmp/pull-secret

else
    : Neither MICROSHIFT_PR nor MICROSHIFT_GIT are set - use release-OCP_VERSION to checkout right scripts and install MicroShift from repositories

    git clone https://github.com/openshift/microshift -b "release-${OCP_VERSION}" ~/microshift

    configure_args=""
    if grep -qw -- "--skip-dnf-update" ~/microshift/scripts/devenv-builder/configure-vm.sh; then
        configure_args="--skip-dnf-update"
    fi

    : Install oc, set up firewall, etc.
    bash -x ~/microshift/scripts/devenv-builder/configure-vm.sh --force-firewall --no-build --no-build-deps ${configure_args} /tmp/pull-secret

    rhocp="rhocp-${OCP_VERSION}-for-rhel-9-$(uname -m)-rpms"
    rc="https://mirror.openshift.com/pub/openshift-v4/$(uname -m)/microshift/ocp/latest-${OCP_VERSION}/el9/os"
    ec="https://mirror.openshift.com/pub/openshift-v4/$(uname -m)/microshift/ocp-dev-preview/latest-${OCP_VERSION}/el9/os"

    if sudo dnf repoquery microshift --quiet --latest-limit 1 --repo "${rhocp}"; then
        sudo subscription-manager repos --enable "${rhocp}"
    elif sudo dnf repoquery microshift --quiet --latest-limit 1 --disablerepo '*' --repofrompath "microshift-rc,${rc}"; then
        enable_mirror_repo "${rc}"
    elif sudo dnf repoquery microshift --quiet --latest-limit 1 --disablerepo '*' --repofrompath "microshift-ec,${ec}"; then
        enable_mirror_repo "${ec}"
    else
        : Build and install MicroShift from source
        bash -x ~/microshift/scripts/devenv-builder/configure-vm.sh --force-firewall ${configure_args} /tmp/pull-secret
        exit 0
    fi

    "${DNF_RETRY}" "install" "microshift*"
    sudo systemctl enable --now microshift
fi
EOF
chmod +x /tmp/install.sh

scp \
    "${MICROSHIFT_CLUSTERBOT_SETTINGS}" \
    /tmp/install.sh \
    /tmp/config.yaml \
    /var/run/rhsm/subscription-manager-org \
    /var/run/rhsm/subscription-manager-act-key \
    "${CLUSTER_PROFILE_DIR}/pull-secret" \
    "${INSTANCE_PREFIX}:/tmp"

ssh "${INSTANCE_PREFIX}" "/tmp/install.sh"
ssh "${INSTANCE_PREFIX}" "sudo cp /var/lib/microshift/resources/kubeadmin/${IP_ADDRESS}/kubeconfig /tmp/kubeconfig && sudo chown \$(whoami). /tmp/kubeconfig"
scp "${INSTANCE_PREFIX}:/tmp/kubeconfig" "${SHARED_DIR}/kubeconfig"
export KUBECONFIG="${SHARED_DIR}/kubeconfig"

# openshift/ci-chat-bot > pkg/manager/prow.go > waitForClusterReachable()
: Creating openshift-apiserver to signal readiness to cluster-bot
oc create namespace openshift-apiserver

: Web Console not set up - kubeconfig and oc debug must be used to SSH into the instance
node_name=$(oc get node -o=jsonpath='{.items[0].metadata.name}')
echo "Use following command to SSH: oc debug node/${node_name}" >"${SHARED_DIR}/console.url"
echo "- Use command provided above to SSH into the host -" >"${SHARED_DIR}/kubeadmin-password"
