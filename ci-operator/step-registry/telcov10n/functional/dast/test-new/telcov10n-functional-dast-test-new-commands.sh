#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

export KUBECONFIG="${SHARED_DIR}/kubeconfig"
unset NAMESPACE

# Setup
oc new-project dast
oc create serviceaccount rapidast -n dast
oc adm policy add-cluster-role-to-user cluster-admin -z rapidast -n dast --rolebinding-name=rapidast-cluster-admin

oc apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: rapidast-config
  namespace: dast
data:
  rapidast-config.yaml: |
    config:
      configVersion: 6
    application:
      shortName: "${OPERATOR_NAME}"
      url: "https://kubernetes.default.svc:443"
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
            apiUrl: "https://kubernetes.default.svc:443/${OPERATOR_API_PATH}"
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
  name: rapidast-pod
  namespace: dast
spec:
  serviceAccountName: rapidast
  restartPolicy: Never
  securityContext:
    runAsUser: 0
  volumes:
  - name: config
    configMap:
      name: rapidast-config
  containers:
  - name: rapidast
    image: quay.io/redhatproductsecurity/rapidast:v2.13.0
    command: ["sh", "-c"]
    args:
    - |
      microdnf install -y tar
      export BEARER_TOKEN="Bearer \$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"
      rapidast.py --config /opt/rapidast/config/rapidast-config.yaml
      touch /tmp/.done
      sleep 300
    volumeMounts:
    - name: config
      mountPath: /opt/rapidast/config
EOF

# Wait for pod to be running
echo "Waiting for scanner pod to start..."
oc wait pod rapidast-pod -n dast --for=condition=Ready --timeout=300s

# Stream rapidast logs to stdout for debugging; background so polling loop can proceed
oc logs -n dast rapidast-pod -c rapidast -f & LOGS_PID=$!

# Wait for sentinel file
echo "Waiting for scan to complete..."
until oc exec -n dast rapidast-pod -c rapidast -- test -f /tmp/.done 2>/dev/null; do
  sleep 15
done

kill "${LOGS_PID}" 2>/dev/null || true

# Copy results directly from rapidast container (tar now available)
echo "Collecting results..."
mkdir -p "${ARTIFACT_DIR}/${OPERATOR_NAME}"
oc cp "dast/rapidast-pod:/opt/rapidast/results" "${ARTIFACT_DIR}/${OPERATOR_NAME}"
