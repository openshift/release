#!/usr/bin/env bash
# Create the StorageBasedRemediationTemplate that NodeHealthCheck references as
# its remediationTemplate. The SBR bundle ships this only as an alm-examples
# sample (not auto-created on install), so without this step NHC has no template
# to clone and never creates StorageBasedRemediation CRs — the NHC-driven SBR
# specs (OCP-88880, OCP-88876, OCP-89200, OCP-88879) then time out or skip.
set -euo pipefail

NAMESPACE="${INSTALL_NAMESPACE:-openshift-workload-availability}"
TEMPLATE_NAME="storagebasedremediationtemplate-sample"

echo "INFO: Applying ${TEMPLATE_NAME} in namespace ${NAMESPACE}"

# spec.template.spec is required by the CRD but intentionally empty: the node to
# remediate is identified by the SBR CR's metadata.name, not by spec fields.
oc apply -f - <<EOF
apiVersion: storage-based-remediation.medik8s.io/v1alpha1
kind: StorageBasedRemediationTemplate
metadata:
  name: ${TEMPLATE_NAME}
  namespace: ${NAMESPACE}
spec:
  template:
    spec: {}
EOF

echo "INFO: Waiting for ${TEMPLATE_NAME} to be present"
for i in $(seq 1 12); do
  if oc get storagebasedremediationtemplate "${TEMPLATE_NAME}" -n "${NAMESPACE}" -o name &>/dev/null; then
    echo "INFO: ${TEMPLATE_NAME} is present"
    exit 0
  fi
  echo "  attempt ${i}/12 — not found yet, waiting 5s..."
  sleep 5
done

echo "ERROR: ${TEMPLATE_NAME} not found in ${NAMESPACE} after 60s"
oc get crd storagebasedremediationtemplates.storage-based-remediation.medik8s.io -o name || true
exit 1
