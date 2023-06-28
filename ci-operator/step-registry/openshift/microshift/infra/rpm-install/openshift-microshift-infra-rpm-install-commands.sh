#!/bin/bash
set -xeuo pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

INSTANCE_PREFIX="${NAMESPACE}"-"${UNIQUE_HASH}"
GOOGLE_PROJECT_ID="$(< ${CLUSTER_PROFILE_DIR}/openshift_gcp_project)"
GOOGLE_COMPUTE_REGION="${LEASED_RESOURCE}"
GOOGLE_COMPUTE_ZONE="$(< ${SHARED_DIR}/openshift_gcp_compute_zone)"
if [[ -z "${GOOGLE_COMPUTE_ZONE}" ]]; then
  echo "Expected \${SHARED_DIR}/openshift_gcp_compute_zone to contain the GCP zone"
  exit 1
fi

gcloud auth activate-service-account --quiet --key-file "${CLUSTER_PROFILE_DIR}"/gce.json
gcloud --quiet config set project "${GOOGLE_PROJECT_ID}"
gcloud --quiet config set compute/zone "${GOOGLE_COMPUTE_ZONE}"
gcloud --quiet config set compute/region "${GOOGLE_COMPUTE_REGION}"

IP_ADDRESS="$(gcloud compute instances describe ${INSTANCE_PREFIX} --format='get(networkInterfaces[0].accessConfigs[0].natIP)')"

mkdir -p "${HOME}"/.ssh
cat << EOF > "${HOME}"/.ssh/config
Host ${INSTANCE_PREFIX}
  User rhel8user
  HostName ${IP_ADDRESS}
  IdentityFile ${CLUSTER_PROFILE_DIR}/ssh-privatekey
  StrictHostKeyChecking accept-new
EOF
chmod 0600 "${HOME}"/.ssh/config

cat <<EOF > /tmp/install.sh
#!/bin/bash
set -xeuo pipefail

rpm --rebuilddb
dnf install subscription-manager -y

subscription-manager register \
  --org="$(cat /var/run/rhsm/subscription-manager-org)" \
  --activationkey="$(cat /var/run/rhsm/subscription-manager-act-key)"

mkdir -p /etc/microshift
cat << EOF2 > /etc/microshift/config.yaml
apiServer:
  subjectAltNames:
  - ${IP_ADDRESS}
EOF2

useradd -m -G wheel microshift
echo -e 'microshift\tALL=(ALL)\tNOPASSWD: ALL' > /etc/sudoers.d/microshift

OPTS=""
if grep "\-\-no-build-deps" /tmp/configure-vm.sh; then
  OPTS="--no-build-deps --force-firewall"
fi
cd /home/microshift && sudo -nu microshift bash -x /tmp/configure-vm.sh --no-build \${OPTS} /tmp/pull-secret

mkdir -p /tmp/rpms
tar -xhvf /tmp/rpms.tar --strip-components 2 -C /tmp/rpms
dnf localinstall -y \$(find /tmp/rpms/ -iname "*\$(uname -p)*" -or -iname '*noarch*')

# 4.12 and 4.13 don't set up cri-o pull secret in case of --no-build
if [ ! -e /etc/crio/openshift-pull-secret ]; then
    cp /tmp/pull-secret /etc/crio/openshift-pull-secret
    chmod 600 /etc/crio/openshift-pull-secret
fi
EOF
chmod +x /tmp/install.sh

scp \
  /rpms.tar \
  /tmp/install.sh \
  /microshift/scripts/devenv-builder/configure-vm.sh \
  "${CLUSTER_PROFILE_DIR}/pull-secret" \
  "${INSTANCE_PREFIX}:/tmp"

ssh "${INSTANCE_PREFIX}" "sudo /tmp/install.sh"

gcloud compute firewall-rules update "${INSTANCE_PREFIX}" --allow tcp:22,icmp,tcp:80,tcp:443,tcp:6443
