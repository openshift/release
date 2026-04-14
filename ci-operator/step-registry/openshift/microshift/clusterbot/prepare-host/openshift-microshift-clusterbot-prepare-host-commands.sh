#!/bin/bash
set -xeuo pipefail

# shellcheck disable=SC1091
source "${SHARED_DIR}/ci-functions.sh"
ci_script_prologue
trap_subprocesses_on_term

cat <<EOF >/tmp/config.yaml
apiServer:
  subjectAltNames:
  - ${IP_ADDRESS}
EOF

MICROSHIFT_CLUSTERBOT_SETTINGS="${SHARED_DIR}/microshift-clusterbot-settings"

cat <<'EOF' >/tmp/install.sh
#!/bin/bash
set -xeuo pipefail

source /tmp/ci-functions.sh
ci_subscription_register
download_microshift_scripts

hash git || "${DNF_RETRY}" "install" "git-core"

source /tmp/microshift-clusterbot-settings

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

elif [[ -n "${MICROSHIFT_NIGHTLY:-}" ]]; then
    : MICROSHIFT_NIGHTLY is set - install from cached nightly RPMs

    git clone https://github.com/openshift/microshift -b "release-${OCP_VERSION}" ~/microshift

    configure_args=""
    if grep -qw -- "--skip-dnf-update" ~/microshift/scripts/devenv-builder/configure-vm.sh; then
        configure_args="--skip-dnf-update"
    fi

    : Set up firewall, oc, etc. without building
    bash -x ~/microshift/scripts/devenv-builder/configure-vm.sh --force-firewall --no-build --no-build-deps ${configure_args} /tmp/pull-secret

    : Download nightly RPMs from S3 directly on EC2
    if [[ ! -f /tmp/brew-rpms-s3-path ]]; then
        echo "ERROR: brew-rpms-s3-path not found"
        exit 1
    fi

    NIGHTLY_S3_PATH=$(cat /tmp/brew-rpms-s3-path)
    echo "Downloading nightly RPMs from: ${NIGHTLY_S3_PATH}"

    # Install AWS CLI on EC2 (CI pod has its own installation for S3 search)
    "${DNF_RETRY}" "install" "unzip"
    curl -s "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" -o /tmp/awscliv2.zip
    unzip -q /tmp/awscliv2.zip -d /tmp
    sudo /tmp/aws/install --install-dir /usr/local/aws-cli --bin-dir /usr/local/bin
    rm -rf /tmp/awscliv2.zip /tmp/aws

    # Configure AWS credentials
    mkdir -p ~/.aws
    chmod 0700 ~/.aws

    # Disable tracing for credential handling
    set +x
    cat > ~/.aws/credentials <<CREDS
[microshift-ci]
aws_access_key_id = $(cat /tmp/aws_access_key_id)
aws_secret_access_key = $(cat /tmp/aws_secret_access_key)
CREDS
    set -x

    chmod -R go-rwx ~/.aws
    export AWS_PROFILE=microshift-ci

    # Download brew-rpms.tar from S3
    aws s3 cp "${NIGHTLY_S3_PATH}" /tmp/brew-rpms.tar
    echo "Downloaded: $(ls -lh /tmp/brew-rpms.tar)"

    # Extract and install
    tar xf /tmp/brew-rpms.tar -C /tmp/
    echo "Extracted nightly RPMs:"
    find /tmp/brew-rpms -name "*.rpm" -type f

    # Find the RPM directory for the current architecture and OCP version
    rpm_arch=$(uname -m)

    # Look specifically for nightly builds
    rpm_dir="/tmp/brew-rpms/${OCP_VERSION}-nightly/${rpm_arch}"

    if [[ ! -d "${rpm_dir}" ]]; then
        echo "ERROR: No nightly RPMs found for OCP version ${OCP_VERSION} and architecture ${rpm_arch}"
        echo "Expected directory: ${rpm_dir}"
        echo "Available directories in brew-rpms:"
        find /tmp/brew-rpms -type d -name "${rpm_arch}" | sort
        echo "NOTE: nightly=true is for installing nightly builds only."
        echo "For EC/RC/zstream, use the standard installation (without nightly=true)."
        exit 1
    fi

    echo "Installing nightly RPMs from: ${rpm_dir}"
    ls -1 "${rpm_dir}"/*.rpm

    sudo dnf install -y "${rpm_dir}"/*.rpm

    echo "Installed MicroShift version:"
    rpm -q microshift microshift-networking microshift-selinux

    # Clean up AWS credentials
    rm -rf ~/.aws /tmp/aws_access_key_id /tmp/aws_secret_access_key /tmp/brew-rpms-s3-path
    rm -rf /tmp/brew-rpms.tar /tmp/brew-rpms

    sudo systemctl enable --now microshift

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

    # `dnf repoquery` returns 1 when the repository is not available,
    # but returns 0 when the repo is up and package is not present.
    released=$(sudo dnf repoquery microshift --quiet --latest-limit 1 --repo "${rhocp}" || true)
    if [[ -n "${released}" ]]; then
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

files_to_copy=(
    "${MICROSHIFT_CLUSTERBOT_SETTINGS}"
    "${SHARED_DIR}/ci-functions.sh"
    /tmp/install.sh
    /tmp/config.yaml
    /var/run/rhsm/subscription-manager-org
    /var/run/rhsm/subscription-manager-act-key
    "${CLUSTER_PROFILE_DIR}/pull-secret"
)

# Add AWS credentials for nightly RPM download (if using nightly=true)
if [[ -f "${SHARED_DIR}/brew-rpms-s3-path" ]]; then
    files_to_copy+=("${SHARED_DIR}/brew-rpms-s3-path")
    files_to_copy+=("${SHARED_DIR}/aws_access_key_id")
    files_to_copy+=("${SHARED_DIR}/aws_secret_access_key")
fi

scp "${files_to_copy[@]}" "${INSTANCE_PREFIX}:/tmp"

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
