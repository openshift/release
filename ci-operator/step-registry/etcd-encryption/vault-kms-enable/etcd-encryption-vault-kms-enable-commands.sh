#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

if [[ -n "${SHARED_DIR:-}" && -f "${SHARED_DIR}/kubeconfig" ]]; then
  export KUBECONFIG="${SHARED_DIR}/kubeconfig"
fi

date -u "+%Y-%m-%dT%H:%M:%SZ"
[ -f "${SHARED_DIR}/proxy-conf.sh" ] && source "${SHARED_DIR}/proxy-conf.sh"

VAULT_KMS_CONFIG_CRD_URL="https://raw.githubusercontent.com/kevinrizza/vault-kms-plugin-openshift-provider/main/bundle/manifests/kms.openshift.io_vaultkmsconfigs.yaml"
APISERVER_ENCRYPTION_PATCH='{"spec":{"encryption":{"type":"KMS","kms":{"pluginConfig":{"apiVersion":"kms.openshift.io/v1alpha1","resource":"vaultkmsconfigs","name":"'"${VAULT_KMS_CONFIG_NAME}"'"}}}}}'

# 1. Apply the VaultKMSConfig CRD that the APIServer encryption config
#    references. Idempotent: etcd-encryption-vault-configure applies the same
#    manifest in the setup chain.
curl -fsSL "${VAULT_KMS_CONFIG_CRD_URL}" | oc apply -f -

# 2. Let the cluster settle after installation before patching the APIServer
#    config, so the patch does not race transient API instability and no retry
#    is needed.
oc adm wait-for-stable-cluster --minimum-stable-period=30s --timeout=20m

# 3. Enable KMS etcd encryption on the APIServer config.
oc patch apiserver cluster --type merge -p "${APISERVER_ENCRYPTION_PATCH}"
echo "INFO - KMS encryption enabled on APIServer cluster"

# 4. Wait for every apiserver operator to finish migrating its resources, the
#    same operators the kas-o encryption e2e suites cover. A single apiserver
#    revision rollout plus migration is budgeted at up to ~80 minutes by the
#    library-go e2e helpers.
TIMEOUT_MINUTES=80
DEADLINE=$(( $(date +%s) + TIMEOUT_MINUTES * 60 ))
while true; do
  ALL_ENCRYPTED=true
  for resource in kubeapiservers.operator.openshift.io openshiftapiservers.operator.openshift.io authentications.operator.openshift.io; do
    REASON="$(oc get "${resource}" cluster -o jsonpath='{.status.conditions[?(@.type=="Encrypted")].reason}' 2>/dev/null || true)"
    if [[ "${REASON}" != "EncryptionCompleted" ]]; then
      ALL_ENCRYPTED=false
      echo "INFO - ${resource}: Encrypted=${REASON:-<unset>}, waiting for migration to complete"
    fi
  done
  if [[ "${ALL_ENCRYPTED}" == "true" ]]; then
    echo "INFO - all apiserver operators report Encrypted reason=EncryptionCompleted"
    break
  fi
  if [[ "$(date +%s)" -gt "${DEADLINE}" ]]; then
    echo "ERROR: timed out after ${TIMEOUT_MINUTES}m waiting for the Encrypted conditions" >&2
    exit 1
  fi
  sleep 30
done

# 5. Let the cluster settle before the job continues (e.g. before an upgrade).
oc adm wait-for-stable-cluster --minimum-stable-period=30s --timeout=20m

date -u "+%Y-%m-%dT%H:%M:%SZ"
echo "INFO - KMS etcd encryption enabled and migration completed"
