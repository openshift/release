#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [ -x "$HOME/fix_uid.sh" ]; then
  "$HOME/fix_uid.sh"
fi

CLUSTER_HV_IP="$(cat "$SHARED_DIR/hv-ip" 2>/dev/null || echo 10.6.34.246)"
BASTION_IP="$(cat /var/run/bastion-ip/bastionip)"
BASTION_USER="$(cat /var/run/bastion-user/bastionuser)"
SSH_PKEY="${HOME}/key"
cp /var/run/ci-key/cikey "$SSH_PKEY"
chmod 600 "$SSH_PKEY"
COMMON_SSH_ARGS="-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o ServerAliveInterval=30"
hv_ssh() {
  ssh -i "${SSH_PKEY}" ${COMMON_SSH_ARGS} -C -o BatchMode=yes \
    -o "ProxyCommand=ssh -i ${SSH_PKEY} ${COMMON_SSH_ARGS} -o BatchMode=yes -W %h:%p -q ${BASTION_USER}@${BASTION_IP}" \
    "kni@${CLUSTER_HV_IP}" "$@"
}

hv_ssh "command -v podman >/dev/null 2>&1" || { echo "ERROR: hypervisor is missing podman"; exit 1; }
hv_ssh "podman image exists registry.ci.openshift.org/ci/telco-runner:latest >/dev/null 2>&1 || podman pull registry.ci.openshift.org/ci/telco-runner:latest >/dev/null 2>&1" \
  || { echo "ERROR: unable to pull the telco-runner image on the hypervisor"; exit 1; }

# Reuse the test runner's shared directory and artifacts. If the test step did
# not create them, seed from the CI SHARED_DIR.
if ! hv_ssh "test -f ~/runner/shared/kubeconfig"; then
  hv_ssh "mkdir -p ~/runner/shared ~/runner/artifacts"
  tar -C "$SHARED_DIR" -cf - . | hv_ssh "tar -C ~/runner/shared -xf -"
fi
hv_ssh "mkdir -p ~/runner/artifacts ~/runner/output"

cat >/tmp/gather.sh <<'GATHER'
#!/bin/bash
set -o nounset
set -o pipefail
if [[ -f /runner/shared/ci.env ]]; then
  # shellcheck source=/dev/null
  source /runner/shared/ci.env
fi
export SHARED_DIR=/runner/shared
export ARTIFACT_DIR=/runner/artifacts
export KUBECONFIG=/runner/shared/kubeconfig
# The standard gather-must-gather uses ${EXTRA_MG_ARGS} under `set -u`
# without initializing it when no custom must-gather image is requested.
export EXTRA_MG_ARGS=""
git clone --depth 1 https://github.com/openshift/release /runner/release || { echo "release clone failed"; exit 0; }
# Bound the clusteroperators inspect: it can hang even when the API is healthy.
GATHER_EXTRA=/runner/release/ci-operator/step-registry/gather/extra/gather-extra-commands.sh
sed -i 's@^\(oc --insecure-skip-tls-verify --request-timeout=5s adm inspect clusteroperators\)@timeout 180s \1@' "$GATHER_EXTRA" || true
bash /runner/release/ci-operator/step-registry/gather/must-gather/gather-must-gather-commands.sh || true
bash /runner/release/ci-operator/step-registry/gather/extra/gather-extra-commands.sh || true
bash /runner/release/ci-operator/step-registry/gather/audit-logs/gather-audit-logs-commands.sh || true
GATHER
hv_ssh "cat > ~/runner/gather.sh" < /tmp/gather.sh

if ! hv_ssh "test -d ~/runner/output/golang-1.22.4"; then
  hv_ssh "podman run --rm --userns=keep-id --entrypoint /bin/bash -v ~/runner/output:/dest:Z registry.ci.openshift.org/ci/telco-runner:latest -c 'cp -a /output/. /dest/'"
fi

hv_ssh "podman run --rm --name telco5g-ptp-gather --net=host --userns=keep-id --entrypoint /bin/bash -v ~/runner/output:/output:Z -v ~/runner:/runner:Z -e MUST_GATHER_TIMEOUT=35m -w /runner registry.ci.openshift.org/ci/telco-runner:latest /runner/gather.sh" || true

mkdir -p "$ARTIFACT_DIR"
if hv_ssh "test -d ~/runner/artifacts"; then
  hv_ssh "tar -C ~/runner/artifacts -cf - ." | tar -C "$ARTIFACT_DIR" -xf - || true
fi
