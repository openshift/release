#!/bin/bash
set -o nounset
set -o pipefail

export KUBECONFIG="${SHARED_DIR}/kubeconfig"
unset NAMESPACE

GCS_KEY_NAME="rapidast-sa-telco_key.json"
GCS_KEY_ON_STEP="/var/run/telco-dast/rapidast-gcs/${GCS_KEY_NAME}"
GCS_KEY_ON_POD="/var/run/secrets/gcs/${GCS_KEY_NAME}"

# Setup
oc new-project dast
oc create serviceaccount rapidast -n dast
oc adm policy add-cluster-role-to-user cluster-admin -z rapidast -n dast
oc adm policy add-scc-to-user anyuid -z rapidast -n dast

# Copy key from this step → Secret on the test cluster so RapidAST pods can mount it
if [[ ! -r "${GCS_KEY_ON_STEP}" ]]; then
  echo "ERROR: GCS key not found at ${GCS_KEY_ON_STEP} (check Vault sync)"
  exit 1
fi

oc create secret generic rapidast-gcs-credentials --from-file="${GCS_KEY_NAME}=${GCS_KEY_ON_STEP}" -n dast

# hostNetwork uses node DNS which can't resolve kubernetes.default.svc
API_SERVER_URL="$(oc whoami --show-server)"
echo "API server URL: ${API_SERVER_URL}"

OVERALL_RC=0

while read -r OPERATOR_NAME OPERATOR_API_PATH; do
  [[ -z "${OPERATOR_NAME}" ]] && continue
  POD_NAME="rapidast-${OPERATOR_NAME}"
  echo "=== Scanning ${OPERATOR_NAME} (${OPERATOR_API_PATH}) ==="

  oc apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: rapidast-config-${OPERATOR_NAME}
  namespace: dast
data:
  rapidast-config.yaml: |
    config:
      configVersion: 6
      googleCloudStorage:
        keyFile: "${GCS_KEY_ON_POD}"
        bucketName: secaut-bucket
        directory: "telco"
    application:
      shortName: "${OPERATOR_NAME}"
      url: "${API_SERVER_URL}"
    general:
      authentication:
        type: "http_header"
        parameters:
          name: "Authorization"
          value_from_var: "BEARER_TOKEN"
      container:
        type: "none"
    scanners:
      zap:
        apiScan:
          apis:
            apiUrl: "${API_SERVER_URL}/${OPERATOR_API_PATH}"
        passiveScan:
          disabledRules: "2,10015,10024,10027,10054,10096,10109,10112"
        activeScan:
          policy: "Kubernetes-API-scan"
    report:
      format: ["json", "html", "sarif"]
EOF

  oc apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${POD_NAME}
  namespace: dast
spec:
  serviceAccountName: rapidast
  hostNetwork: true
  restartPolicy: Never
  securityContext:
    runAsUser: 0
  volumes:
  - name: config
    configMap:
      name: rapidast-config-${OPERATOR_NAME}
  - name: gcs-sa
    secret:
      secretName: rapidast-gcs-credentials
  containers:
  - name: rapidast
    image: quay.io/redhatproductsecurity/rapidast:latest
    command: ["sh", "-c"]
    args:
    - |
      export BEARER_TOKEN="Bearer \$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"
      rapidast.py --config /opt/rapidast/config/rapidast-config.yaml
      touch /tmp/.done
      sleep 300
    volumeMounts:
    - name: config
      mountPath: /opt/rapidast/config
    - name: gcs-sa
      mountPath: /var/run/secrets/gcs
      readOnly: true
EOF

  # Wait for pod to be running
  echo "Waiting for scanner pod to start..."
  if ! oc wait pod "${POD_NAME}" -n dast --for=condition=Ready --timeout=600s; then
    echo "ERROR: ${POD_NAME} failed to start"
    OVERALL_RC=1
    oc delete pod "${POD_NAME}" -n dast --ignore-not-found
    continue
  fi

  # Stream rapidast logs to stdout for debugging; background so polling loop can proceed
  oc logs -n dast "${POD_NAME}" -c rapidast -f & LOGS_PID=$!

  # Wait for sentinel file
  echo "Waiting for scan to complete..."
  until oc exec -n dast "${POD_NAME}" -c rapidast -- test -f /tmp/.done 2>/dev/null; do
    sleep 15
  done

  kill "${LOGS_PID}" 2>/dev/null || true

  # Copy results using python tar stream (no tar binary needed in pod)
  echo "Collecting results..."
  mkdir -p "${ARTIFACT_DIR}/${OPERATOR_NAME}"
  if ! oc exec -n dast "${POD_NAME}" -- python3 -c \
    "import tarfile,sys; tar=tarfile.open(fileobj=sys.stdout.buffer,mode='w|'); tar.add('/opt/rapidast/results',arcname='results'); tar.close()" \
    | tar xf - -C "${ARTIFACT_DIR}/${OPERATOR_NAME}"; then
    echo "ERROR: failed to collect results for ${OPERATOR_NAME}"
    OVERALL_RC=1
  fi

  oc delete pod "${POD_NAME}" -n dast --ignore-not-found

done <<< "${OPERATORS_DAST}"

exit ${OVERALL_RC}
