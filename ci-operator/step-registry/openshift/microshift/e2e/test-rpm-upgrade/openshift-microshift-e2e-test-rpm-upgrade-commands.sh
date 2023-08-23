#!/bin/bash

set -xeuo pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

IP_ADDRESS="$(cat ${SHARED_DIR}/public_address)"
HOST_USER="$(cat ${SHARED_DIR}/ssh_user)"

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

microshift_version(){
    local v
    v="$(sed -En 's|OCP_VERSION := (4\.[0-9]+).*|\1|p' /microshift/Makefile.version."$(uname -i)".var)"
    [ -n "${v}" ] || exit 1
    echo "${v}"
}

decrement_minor(){
    local ver="${1}"
    local major=${ver%.*}
    local minor="${ver#*.}"
    [ -z "${major}" ] && exit 1
    [ -z "${minor}" ] && exit 1
    echo "$major.$(( --minor ))"
}

latest_release_ver="$(decrement_minor "$(microshift_version)")"
release_repo="rhocp-${latest_release_ver}-for-rhel-9-x86_64-rpms"

# install_and_upgrade.sh
# The test instance has been created and the PR's source has been deployed. We need to start from the y-1 release though.
# Wipe the current microshift installation and install the latest y-1 release rpm.
cat <<EOF > "${HOME}"/install_and_upgrade.sh
#!/bin/bash
set -xeou pipefail

# The latest version of microshift was installed during the infra setup. Tear it down before testing
microshift-cleanup-data --all <<<1
rpm -qa|grep microshift|xargs dnf remove -y
rm -rf /var/lib/microshift

# Once the env has been cleaned up, install the latest y-1 rpm release, relative to the PR's y-stream.
subscription-manager repos --enable "${release_repo}"
dnf install microshift microshift-greenboot -y
systemctl enable --now microshift

# wait for microshift to become ready
sudo /etc/greenboot/check/required.d/40_microshift_running_check.sh

systemctl stop microshift

dnf localinstall -y \$(find /tmp/rpms/ -iname "*\$(uname -p)*" -or -iname '*noarch*')

systemctl restart microshift

# wait for microshift to become ready
sudo /etc/greenboot/check/required.d/40_microshift_running_check.sh
EOF
chmod +x "${HOME}"/install_and_upgrade.sh
scp "${HOME}"/install_and_upgrade.sh "${IP_ADDRESS}":~/
ssh "${IP_ADDRESS}" "sudo ~/install_and_upgrade.sh"