#!/bin/bash
set -eu -o pipefail

declare INSTALL_NAMESPACE="${INSTALL_NAMESPACE:-openshift-workload-availability}"
declare CREDENTIALS_SECRET_NAME="${CREDENTIALS_SECRET_NAME:-aws-cloud-fencing-credentials-secret}"

log() { echo "[$(date --utc +%FT%T.%3NZ)] $*"; }

collect_artifacts() {
    log "Collecting debug artifacts..."
    {
        oc get credentialsrequest medik8s-aws-fencing \
            -n openshift-cloud-credential-operator -o yaml \
            > "${ARTIFACT_DIR}/credentialsrequest.yaml" 2>/dev/null
        oc describe secret "${CREDENTIALS_SECRET_NAME}" \
            -n "${INSTALL_NAMESPACE}" \
            > "${ARTIFACT_DIR}/aws-credentials-secret.txt" 2>/dev/null
        oc get events -n openshift-cloud-credential-operator \
            --sort-by='.lastTimestamp' \
            > "${ARTIFACT_DIR}/cco-events.txt" 2>/dev/null
    } || true
}

set_proxy() {
    # shellcheck disable=SC1090
    [[ -f "${SHARED_DIR}/proxy-conf.sh" ]] && {
        log "setting proxy"
        source "${SHARED_DIR}/proxy-conf.sh"
    }
    return 0
}

main() {
    log "=== medik8s AWS Credentials ==="
    trap 'collect_artifacts' EXIT
    set_proxy

    log "Creating CredentialsRequest for AWS EC2 fencing..."
    cat <<EOF | oc apply -f -
apiVersion: cloudcredential.openshift.io/v1
kind: CredentialsRequest
metadata:
  name: medik8s-aws-fencing
  namespace: openshift-cloud-credential-operator
spec:
  serviceAccountNames:
  - fence-agents-remediation-controller-manager
  secretRef:
    name: ${CREDENTIALS_SECRET_NAME}
    namespace: ${INSTALL_NAMESPACE}
  providerSpec:
    apiVersion: cloudcredential.openshift.io/v1
    kind: AWSProviderSpec
    statementEntries:
    - action:
      - ec2:DescribeInstances
      - ec2:StartInstances
      - ec2:StopInstances
      - ec2:RebootInstances
      effect: Allow
      resource: "*"
EOF

    log "Waiting for CCO to provision Secret ${CREDENTIALS_SECRET_NAME} in ${INSTALL_NAMESPACE}..."
    for i in $(seq 1 60); do
        if oc get secret "${CREDENTIALS_SECRET_NAME}" -n "${INSTALL_NAMESPACE}" -o name &>/dev/null; then
            log "Secret ${CREDENTIALS_SECRET_NAME} found after ${i} attempts"
            oc get secret "${CREDENTIALS_SECRET_NAME}" -n "${INSTALL_NAMESPACE}" \
                -o jsonpath='{.data}' | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'Keys: {list(d.keys())}')" 2>/dev/null || true
            log "=== AWS credentials provisioned successfully ==="
            return 0
        fi
        log "  attempt ${i}/60 — secret not found yet, waiting 5s..."
        sleep 5
    done

    log "ERROR: Secret ${CREDENTIALS_SECRET_NAME} not provisioned after 5 minutes"
    log "--- Debug info ---"
    oc get credentialsrequest medik8s-aws-fencing -n openshift-cloud-credential-operator -o yaml 2>/dev/null || true
    oc get events -n openshift-cloud-credential-operator --sort-by='.lastTimestamp' 2>/dev/null | tail -10 || true
    return 1
}
main
