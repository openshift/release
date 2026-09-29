#!/bin/bash
# Gated wrapper around the shared ssh-bastion step so smoke jobs can share one
# test chain without always deploying a bastion.
#
# On AWS the eparis LoadBalancer hostname is enough for system-tests
# findSSHBastion(). Libvirt OZ has no cloud LB, so this step also records that
# run-tests must port-forward the bastion Service and inject an SSH ProxyCommand.

set -euo pipefail

if [[ "${MEDIK8S_S390X_SSH_BASTION:-false}" != "true" ]]; then
  echo "MEDIK8S_S390X_SSH_BASTION is not true; skipping ssh-bastion setup"
  exit 0
fi

echo "=== Deploying ssh-bastion for medik8s system-tests (s390x OZ) ==="

# Ensure our UID is in /etc/passwd (required for SSH from the step pod).
if ! whoami &>/dev/null; then
  if [[ -w /etc/passwd ]]; then
    echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >> /etc/passwd
  else
    echo "/etc/passwd is not writeable, and user matching this uid is not found." >&2
    exit 1
  fi
fi

mkdir -p /tmp/client
curl -L --fail https://openshift-mirror-list.ci-systems.workers.dev/pub/openshift-v4/clients/oc/latest/linux/oc.tar.gz \
  | tar --directory=/tmp/client -xzf -
PATH=/tmp/client:$PATH
oc version --client

export SSH_BASTION_NAMESPACE=test-ssh-bastion

# Shorten the upstream LB/DNS wait: libvirt OZ never gets a cloud LB ingress.
deploy_script="$(mktemp)"
curl -fsSL https://raw.githubusercontent.com/eparis/ssh-bastion/master/deploy/deploy.sh -o "${deploy_script}"
sed -i 's/retry=120/retry=15/g' "${deploy_script}"
bash -x "${deploy_script}"
rm -f "${deploy_script}"

echo "Waiting for ssh-bastion deployment to become Available..."
oc -n "${SSH_BASTION_NAMESPACE}" rollout status deployment/ssh-bastion --timeout=180s
oc -n "${SSH_BASTION_NAMESPACE}" get pods,svc -o wide

bastion_host="$(oc get service -n "${SSH_BASTION_NAMESPACE}" ssh-bastion -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
bastion_ip="$(oc get service -n "${SSH_BASTION_NAMESPACE}" ssh-bastion -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"

if [[ -n "${bastion_host}" ]]; then
  echo "ssh-bastion LoadBalancer hostname: ${bastion_host}"
  echo "lb-hostname" > "${SHARED_DIR}/medik8s_ssh_bastion_mode"
  echo "${bastion_host}" > "${SHARED_DIR}/medik8s_ssh_bastion_host"
elif [[ -n "${bastion_ip}" ]]; then
  echo "ssh-bastion LoadBalancer IP: ${bastion_ip}"
  echo "lb-ip" > "${SHARED_DIR}/medik8s_ssh_bastion_mode"
  echo "${bastion_ip}" > "${SHARED_DIR}/medik8s_ssh_bastion_host"
else
  echo "No LoadBalancer ingress (expected on libvirt OZ); run-tests will port-forward svc/ssh-bastion"
  echo "port-forward" > "${SHARED_DIR}/medik8s_ssh_bastion_mode"
fi

echo "=== ssh-bastion ready ==="
