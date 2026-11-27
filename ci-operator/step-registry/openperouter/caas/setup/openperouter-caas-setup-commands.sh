#!/bin/bash

set -euo pipefail

## Functions

# Pipe input into redact() in order to redact secrets from your output, e.g.:
# echo "Authorization: Bearer ya29.a0AfH6SMBx1234567890abcdefghij" | scrub
redact() {
  echo " === redacted output ==="
  sed -r \
      -e 's|(Authorizatio[n]:[[:blank:]]*([Bb]earer[[:blank:]]+)?)[A-Za-z0-9._~+/=-]{16,}|\1[REDACTED]|g' \
      -e 's|([Bb]eare[r][[:blank:]]+)[A-Za-z0-9._~+/=-]{16,}|\1[REDACTED]|g' \
      -e 's|(toke[n]=[[:blank:]]*)([A-Za-z0-9._~+/=-]{16,})|\1[REDACTED]|g' \
      -e 's#-----BEGI[N] (CERTIFICATE|PRIVATE KEY|RSA PRIVATE KEY|EC PRIVATE KEY|PUBLIC KEY)-----#[REDACTED:PEM-HEADER]#g' \
      -e 's#-----EN[D] (CERTIFICATE|PRIVATE KEY|RSA PRIVATE KEY|EC PRIVATE KEY|PUBLIC KEY)-----#[REDACTED:PEM-FOOTER]#g' \
      -e 's#("[A-Za-z0-9_-]*(passwo[r]d|secre[t]|toke[n]|beare[r]|credentia[l])(_?(key|code))?[[:blank:]]*"[[:blank:]]*:[[:blank:]]*")([^"\\]|\\.)+#\1[REDACTED]#Ig' \
      -e 's/\{"auths":.*\}/{"auths":[REDACTED]}/g' \
      -e 's/\{\\"auths\\":.*\}/{"auths":[REDACTED]}/g'
}

echo "************ openperouter caas setup ************"

export DEPLOYMENT_MODE="${DEPLOYMENT_MODE:-day0}"
if [[ "${DEPLOYMENT_MODE}" != "day0" ]] && \
     [[ "${DEPLOYMENT_MODE}" != "standard" ]]; then
  echo "Unsupported DEPLOYMENT_MODE: '${DEPLOYMENT_MODE}'"
  exit 1
fi
echo "DEPLOYMENT_MODE: ${DEPLOYMENT_MODE}"

export DATAPLANE="${DATAPLANE:-kernel}"
if [[ "${DATAPLANE}" != "kernel" ]] && \
     [[ "${DATAPLANE}" != "grout" ]]; then
  echo "Unsupported DATAPLANE: '${DATAPLANE}'"
  exit 1
fi
echo "DATAPLANE: ${DATAPLANE}"

if [[ -z "${RELEASE_IMAGE_LATEST:-}" ]]; then
  echo "RELEASE_IMAGE_LATEST must be set and non-empty."
  echo "Make sure to set releases.latest in the test configuration. See 'Testing With an Ephemeral OpenShift Release'"
  echo "in the documentation."
  exit 1
fi
echo "RELEASE_IMAGE_LATEST: ${RELEASE_IMAGE_LATEST}"

if [[ -z "${IMAGE_OPENPEROUTER_OPERATOR:-}" ]]; then
  echo "IMAGE_OPENPEROUTER_OPERATOR must be set and non-empty."
  echo "Make sure to build the openperouter-operator image as part of the test configuration."
  echo "See 'Referring to Images in Tests' in the documentation."
  exit 1
fi
echo "IMAGE_OPENPEROUTER_OPERATOR: ${IMAGE_OPENPEROUTER_OPERATOR}"

# SHARED_DIR is the CI-provided workspace shared by all steps in the workflow.
# The ofcir-acquire step writes packet-conf.sh there; it defines the leased
# host's IP and SSHOPTS and verifies root SSH access.
# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

REPO_DIR="/opt/openperouterday0openshift"
PULL_SECRET="/opt/pull_secret.json"
export REPO_DEPLOYMENT="${DEPLOYMENT_MODE}-${DATAPLANE}"

echo "REPO_DIR: ${REPO_DIR}"
echo "REPO_DEPLOYMENT: ${REPO_DEPLOYMENT}"

echo "### Copying pull secret to remote host"
if [[ ! -f "${CLUSTER_PROFILE_DIR}/pull-secret" ]]; then
  echo "ERROR: ${CLUSTER_PROFILE_DIR}/pull-secret not found"
  exit 1
fi
ssh "${SSHOPTS[@]}" "root@${IP}" "mkdir -p /opt"
scp "${SSHOPTS[@]}" "${CLUSTER_PROFILE_DIR}/pull-secret" "root@${IP}:${PULL_SECRET}"

echo "### Generating remote setup script with substituted variables"
remote_setup_script="$(mktemp /tmp/openperouter-caas-setup.XXXXXX.sh)"
remote_wait_script="$(mktemp /tmp/openperouter-caas-wait.XXXXXX.sh)"
cat << REMOTE_SETUP > "${remote_setup_script}"
set -euo pipefail

echo "  ===> Installing required packages"
yum install -y \
  butane \
  coreos-installer \
  podman \
  pip \
  go \
  ansible-core \
  jq \
  git \
  nmstate \
  dnsmasq \
  libvirt-client \
  qemu-img \
  libvirt \
  qemu-kvm
python3 -m pip install yq

echo "  ===> Installing oc and kubectl clients"
tmp_dir=\$(mktemp -d)
[[ -z "\${tmp_dir}" ]] && echo "Issue creating temp_dir: '\${tmp_dir}'" && exit 1
pushd "\${tmp_dir}"
curl -f -L -O https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/openshift-client-linux.tar.gz
tar -zxvf openshift-client-linux.tar.gz
mv oc /usr/local/bin/
mv kubectl /usr/local/bin/
popd
rm -Rf "\${tmp_dir}"

echo "  ===> Starting libvirtd"
systemctl enable --now libvirtd

echo "  ===> Cloning ${OPENPEROUTER_DAY0_REPO} (branch: ${OPENPEROUTER_DAY0_BRANCH}) to ${REPO_DIR}"
git clone --depth 1 --branch "${OPENPEROUTER_DAY0_BRANCH}" "${OPENPEROUTER_DAY0_REPO}" "${REPO_DIR}"

echo "  ===> Ensuring an SSH keypair exists for appliance generation"
if [[ ! -f /root/.ssh/id_rsa ]]; then
  ssh-keygen -t rsa -b 2048 -f /root/.ssh/id_rsa -N ''
fi

echo "  ===> Building appliance and config image"
export SSH_PUB_KEY="\$(cat /root/.ssh/id_rsa.pub)"
# export OPENSHIFT_RELEASE_IMAGE="${RELEASE_IMAGE_LATEST}"
export IMAGE_OPENPEROUTER_OPERATOR="${IMAGE_OPENPEROUTER_OPERATOR}"
export OCP_RELEASE_VERSION=\$(
  oc adm release info --registry-config ${PULL_SECRET} ${RELEASE_IMAGE_LATEST} -ojsonpath='{.metadata.version}' |
    cut -d. -f1,2
)
pushd "${REPO_DIR}/${REPO_DEPLOYMENT}"
  appliance/generate_appliance.sh "${PULL_SECRET}"
  configimage/generate_config_image.sh "${PULL_SECRET}"
popd

echo "  ===> Deploying the virtual environment"
export MASTER_MEMORY="${MASTER_MEMORY}"
export MASTER_DISK="${MASTER_DISK}"
export MASTER_VCPU="${MASTER_VCPU}"
export WORKER_MEMORY="${WORKER_MEMORY}"
export WORKER_DISK="${WORKER_DISK}"
export WORKER_VCPU="${WORKER_VCPU}"
"${REPO_DIR}/site/vmlab/lab-up.sh" \
  "${REPO_DIR}/${REPO_DEPLOYMENT}/appliance/appliance.iso" \
  "${REPO_DIR}/${REPO_DEPLOYMENT}/configimage/configimage/agentconfig.noarch.iso"
REMOTE_SETUP

echo "### Generating remote wait script with substituted variables"
cat << REMOTE_WAIT > "${remote_wait_script}"
set -euo pipefail

echo "  ===> Waiting for the OpenShift cluster to become available"
export KUBECONFIG="${REPO_DIR}/${REPO_DEPLOYMENT}/configimage/configimage/auth/kubeconfig"

deadline=\$(( SECONDS + ${VERIFY_TIMEOUT_MIN:-60} * 60 ))
request_timeout="--request-timeout=2s"
oc="oc \${request_timeout}"
while (( SECONDS < deadline )); do
  echo "  ===> cluster status at \$(date -u '+%Y-%m-%d %H:%M:%S UTC')   ===>"
  for cmd in \
    "ip vrf exec red \${oc} get nodes" \
    "ip vrf exec red \${oc} get clusterversion" \
    "ip vrf exec red \${oc} get co"; do
     echo "  -- \${cmd} --"
     \${cmd} || true
  done

  cluster_json="\$(ip vrf exec red \${oc} get clusterversion -o json 2>/dev/null || true)"
  available="\$(echo "\${cluster_json}" | jq -r '.items[0].status.conditions[] | select(.type=="Available").status' || true)"
  progressing="\$(echo "\${cluster_json}" | jq -r '.items[0].status.conditions[] | select(.type=="Progressing").status' || true)"
  echo "clusterversion: Available=\${available:-<unset>} Progressing=\${progressing:-<unset>}"

  if [[ "\${available}" == "True" && "\${progressing}" == "False" ]]; then
    echo "  ===> OpenShift cluster is ready"
    exit 0
  fi

  sleep "${VERIFY_INTERVAL_SEC:-60}"
done

echo "ERROR: OpenShift cluster did not become ready within ${VERIFY_TIMEOUT_MIN:-60} minutes"
exit 1
REMOTE_WAIT

echo "### Copying remote setup and remote wait scripts to remote host"
scp "${SSHOPTS[@]}" "${remote_setup_script}" "root@${IP}:/tmp/openperouter-caas-setup.sh"
scp "${SSHOPTS[@]}" "${remote_wait_script}" "root@${IP}:/tmp/openperouter-caas-wait.sh"
rm -f "${remote_setup_script}"
rm -f "${remote_wait_script}"

set +e
echo "### Running remote setup (clone, appliance build, lab-up, cluster verification)"
ssh "${SSHOPTS[@]}" "root@${IP}" bash /tmp/openperouter-caas-setup.sh 2>&1 | redact
test_setup_rc="$?"
if [[ "${test_setup_rc}" -ne 0 ]]; then
  echo "### openperouter caas setup FAILED"
  exit "${test_setup_rc}"
fi

echo "### Running remote wait"
ssh "${SSHOPTS[@]}" "root@${IP}" bash /tmp/openperouter-caas-wait.sh 2>&1 | redact
test_wait_rc="$?"
if [[ "${test_wait_rc}" -ne 0 ]]; then
  echo "### openperouter caas wait FAILED"
  exit "${test_wait_rc}"
fi

echo "### openperouter caas setup done"
