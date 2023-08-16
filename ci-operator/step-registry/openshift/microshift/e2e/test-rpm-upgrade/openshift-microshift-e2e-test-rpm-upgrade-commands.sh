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
    v="$(sed -En 's|OCP_VERSION := (4\.[0-9]+).*|\1|p' ./Makefile.version.x86_64.var)"
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

wait_for_microshift_ready(){
    # Disable exit-on-error and enable command logging with a timestamp
    set +e
    set -x
    PS4='+ $(date "+%T.%N")\011'
    retries=3
    while [ ${retries} -gt 0 ] ; do
      ((retries-=1))

      oc wait \
        pod \
        --for=condition=ready \
        -l='app.kubernetes.io/name=topolvm-csi-driver' \
        -n openshift-storage \
        --timeout=5m
      [ $? -eq 0 ] && return 0

      # Image pull operation sometimes get stuck for topolvm images
      # Delete topolvm pods to retry image pull operation
      oc delete \
        pod \
        -l='app.kubernetes.io/name=topolvm-csi-driver' \
        -n openshift-storage \
        --timeout=30s
    done

    # All retries waiting for the cluster failed
    return 1
}

latest_release_ver="$(decrement_minor "$(microshift_version)")"
release_repo="rhocp-${latest_release_ver}-for-rhel-9-x86_64-rpms"

cat <<EOF > install_latest_release.sh
#!/bin/bash
set -xeou pipefail

# The latest version of microshift was installed during the infra setup. Tear it down before testing
microshift-cleanup-data --all <<<1
rpm -qa|grep microshift|xargs dnf uninstall -y
rm -rf /etc/microshift /var/lib/microshift

subscription-manager repos --enable "${release_repo}"
dnf install microshift -y

systemctl enable --now microshift

# test if microshift is running
sudo systemctl status microshift

# test if microshift created the kubeconfig under /var/lib/microshift/resources/kubeadmin/kubeconfig
while ! test -f "/var/lib/microshift/resources/kubeadmin/kubeconfig"; do
    echo "Waiting for kubeconfig..."
    sleep 10;
done
EOF
scp ./install_latest_release.sh "${IP_ADDRESS}":~/

ssh "${IP_ADDRESS}" "sudo ~/install_latest_release.sh"
export KUBECONFIG
KUBECONFIG="$(mktemp -d)/kubeconfig"
ssh "${IP_ADDRESS}" "sudo cat /var/lib/microshift/resources/kubeadmin/${IP_ADDRESS}/kubeconfig" >"${KUBECONFIG}"
wait_for_microshift_ready
ssh "${IP_ADDRESS}" "sudo /etc/greenboot/check/required.d/40_microshift_running_check.sh"

# At this point, the 4.y-1 release should be up and running. Now upgrade to the latest
cat <<EOF >install_branch_rpms.sh
#!/bin/bash
systemctl stop microshift
dnf localinstall -y \$(find /tmp/rpms/ -iname "*\$(uname -p)*" -or -iname '*noarch*')
systemctl restart microshift
systemctl status microshift
EOF
scp install_branch_rpms.sh "${IP_ADDRESS}":~/
ssh "${IP_ADDRESS}" "sudo ~/install_branch_rpms.sh"
sleep
wait_for_microshift_ready
ssh "${IP_ADDRESS}" "sudo /etc/greenboot/check/required.d/40_microshift_running_check.sh"
