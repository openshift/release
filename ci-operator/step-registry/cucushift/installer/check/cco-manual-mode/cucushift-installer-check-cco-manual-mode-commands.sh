#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail


if [ -f "${SHARED_DIR}/kubeconfig" ] ; then
    export KUBECONFIG=${SHARED_DIR}/kubeconfig
fi

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
    source "${SHARED_DIR}/proxy-conf.sh"
fi

ret=0

# Check CCO logs
cco_pod=$(oc get pods -n openshift-cloud-credential-operator --no-headers | grep "cloud-credential-operator" | awk '{print $1}')
expected_log="operator in disabled / manual mode"
if oc logs -n openshift-cloud-credential-operator -c cloud-credential-operator ${cco_pod} | grep "${expected_log}"; then
    echo "PASS: Checking CCO logs, found: ${expected_log}"
else
    echo "Error: Expected log \"${expected_log}\" not found"
    ret=$((ret+1))
fi

# Test new secret creation
cat <<EOF >/tmp/test_secret.yaml
apiVersion: v1
kind: Secret
metadata:
  name: test-secret
  namespace: openshift-cloud-credential-operator
data:
  secret_key: $(echo "secret_value" | base64)
EOF
oc create -f /tmp/test_secret.yaml
secret_value=$(oc get secret --no-headers test-secret -n openshift-cloud-credential-operator -ojsonpath='{.data.secret_key}' | base64 -d)
if [[ ${secret_value} == "secret_value" ]]; then
    echo "PASS: new secret creation"
else
    echo "FAIL: new secret creation"
    ret=$((ret+1))
fi

exit $ret