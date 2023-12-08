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
export PS4='+ $(date "+%T.%N") \011'

source /tmp/microshift-clusterbot-settings

if ! sudo subscription-manager status >&/dev/null; then
	sudo subscription-manager register \
		--org="$(cat /tmp/subscription-manager-org)" \
		--activationkey="$(cat /tmp/subscription-manager-act-key)"
fi
hash git || sudo dnf install -y git-core

sudo mkdir -p /etc/microshift
sudo cp /tmp/config.yaml /etc/microshift/config.yaml

if [[ -z "${MICROSHIFT_GIT+x}" ]] || [[ "${MICROSHIFT_GIT}" == "" ]]; then
	: MICROSHIFT_GIT unset or empty - use release-OCP_VERSION to checkout right scripts and install MicroShift from repositories

	git clone https://github.com/openshift/microshift -b "release-${OCP_VERSION}" ~/microshift

	if [[ "${OCP_VERSION}" != "${CURRENT_RELEASE}" ]]; then
		: Enabling right version of RHOCP repositories as the one from configure-vm.sh lags one behind
        : But only for released versions
		sudo subscription-manager config --rhsm.manage_repos=1
		OS_VERSION=$(awk -F: '{print $5}' /etc/system-release-cpe)
		sudo subscription-manager repos \
			--enable "rhocp-${OCP_VERSION}-for-rhel-${OS_VERSION}-$(uname -m)-rpms" \
			--enable "fast-datapath-for-rhel-${OS_VERSION}-$(uname -m)-rpms"
	fi

    : Install oc, set up firewall, etc.
	bash -x ~/microshift/scripts/devenv-builder/configure-vm.sh --force-firewall --no-build --no-build-deps /tmp/pull-secret

    : Fetch get_rel_version_repo.sh from o/microshift main so it is up to date - some release-4.Y might not have it
    curl https://raw.githubusercontent.com/openshift/microshift/main/test/bin/get_rel_version_repo.sh -o /tmp/get_rel_version_repo.sh
    source /tmp/get_rel_version_repo.sh
    export UNAME_M=$(uname -m)
    ver_repo=$(get_rel_version_repo $(echo $OCP_VERSION | cut -d. -f2))
    version=$(echo "${ver_repo}" | cut -d, -f1)
    repo=$(echo "${ver_repo}" | cut -d, -f2)

    if [[ -z "${version+x}" ]] || [[ "${version}" == "" ]]; then
        : version is empty - no RPMs for the release yet - build from source
        bash -x ~/microshift/scripts/devenv-builder/configure-vm.sh --force-firewall /tmp/pull-secret
        exit 0
    fi

    if [[ ! -z "${repo}" ]]; then
        : Repo with EC or RC was found - enable
        sudo tee "/etc/yum.repos.d/microshift-mirror.repo" >/dev/null <<2EOF2
[microshift-mirror]
name=MicroShift mirror repository
baseurl=${repo}
enabled=1
gpgcheck=0
skip_if_unavailable=0
2EOF2
    fi

	sudo dnf install -y "microshift-${version}"
	sudo systemctl enable --now microshift

else
	: MICROSHIFT_GIT is set - clone it, build it, run it

	git clone https://github.com/openshift/microshift -b "${MICROSHIFT_GIT}" ~/microshift
	bash -x ~/microshift/scripts/devenv-builder/configure-vm.sh --force-firewall /tmp/pull-secret
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
