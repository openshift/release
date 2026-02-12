#!/bin/bash

set -euo pipefail
set -x

if [[ ${DYNAMIC_IMAGE_REGISTRY_ENABLED} == "false" ]]; then
  echo "SKIP ....."
  exit 0
fi

if [[ -f "${SHARED_DIR}/proxy-conf.sh" ]]; then
    source "${SHARED_DIR}/proxy-conf.sh"
fi

# Get hosted cluster endpoint
if [ ! -f "${SHARED_DIR}/nested_kubeconfig" ]; then
    exit 1
fi
export KUBECONFIG="${SHARED_DIR}/nested_kubeconfig"

# The CA key and certificate should exist to proceed
if [[ ! -f "${SHARED_DIR}"/hc_ca.key || ! -f "${SHARED_DIR}"/hc_ca.crt ]]; then
    echo "TLS CA cert or key not found in ${SHARED_DIR}"
    exit 1
fi

HYPERSHIFT_NAMESPACE="${HYPERSHIFT_NAMESPACE:-clusters}"
CLUSTER_NAME=$(oc --kubeconfig "${SHARED_DIR}"/kubeconfig get hostedclusters -n "${HYPERSHIFT_NAMESPACE}" -o jsonpath='{.items[0].metadata.name}')
hc_base_domain=$(oc --kubeconfig "${SHARED_DIR}"/kubeconfig get hc "$CLUSTER_NAME" -n "${HYPERSHIFT_NAMESPACE}" -o jsonpath='{.spec.dns.baseDomain}')
cpo_endpoint=$(oc --kubeconfig "${SHARED_DIR}"/kubeconfig get hc "$CLUSTER_NAME" -n "${HYPERSHIFT_NAMESPACE}" -o jsonpath='{.status.controlPlaneEndpoint.host}')
cpo_endpoint_base="${cpo_endpoint#*.}"
hc_base_dns="*.apps.${CLUSTER_NAME}.${hc_base_domain}"
cpo_endpoint_dns="*.apps.${CLUSTER_NAME}.${cpo_endpoint_base}"
mapfile -t DNS_NAMES < <(printf "%s\n" "$hc_base_dns" "$cpo_endpoint_dns" | sort -u)

echo "Create TLS Cert/Key pairs..."
temp_dir=$(mktemp -d)

cat >>"$temp_dir"/openssl.cnf <<EOF
[req]
req_extensions = v3_req
distinguished_name = req_distinguished_name
[req_distinguished_name]
[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
subjectAltName = @alt_names
[alt_names]
EOF

i=1
for dns in "${DNS_NAMES[@]}"; do
  echo "DNS.$i = $dns" >> "$temp_dir"/openssl.cnf
  ((i++))
done

# generate tls pair
openssl genrsa -out "$temp_dir"/hc.key 2048 2>/dev/null
openssl req -sha256 -new -key "$temp_dir"/hc.key -out "$temp_dir"/hc.csr -subj "/C=CN/ST=Beijing/L=BJ/O=Hypershift team/OU=Hypershift QE Team/CN=${hc_base_dns}" -config "$temp_dir"/openssl.cnf 2>/dev/null
openssl x509 -sha256 -req -in "$temp_dir"/hc.csr -CA "${SHARED_DIR}"/hc_ca.crt -CAkey "${SHARED_DIR}"/hc_ca.key -CAcreateserial -out "$temp_dir"/hc.crt -days 365 -extensions v3_req -extfile "$temp_dir"/openssl.cnf 2>/dev/null

if [ -e "$temp_dir"/hc.key ]; then
    echo "Create the TLS/SSL key file successfully"
else
    echo "!!! Fail to create the TLS/SSL key file "
    return 1
fi

if [ -e "$temp_dir"/hc.crt ]; then
    echo "Create the TLS/SSL cert file successfully"
else
    echo "!!! Fail to create the TLS/SSL cert file "
    return 1
fi

# now the hosted cluster has been created, we are trying to create an image registry within the hosted cluster

# the tls certificates exists in the shared dir
REGISTRY_NAMESPACE="${REGISTRY_NAMESPACE:-test-registry}"
REGISTRY_IMAGE="${REGISTRY_IMAGE:-quay.io/openshifttest/registry:2}"
REGISTRY_NAME="${REGISTRY_NAME:-my-registry}"
TLS_SECRET_NAME="${TLS_SECRET_NAME:-my-registry-tls-secret}"
REGISTRY_USERNAME="${REGISTRY_USERNAME:-my-registry-user}"
REGISTRY_PASSWORD="${REGISTRY_PASSWORD:-my-registry-password}"

# Creat the registry namespace if not exists
oc get namespace "$REGISTRY_NAMESPACE" &>/dev/null || oc create namespace "$REGISTRY_NAMESPACE"

# Create the tls secret in the registry namespace if not created yet
oc get secret "$TLS_SECRET_NAME" -n "$REGISTRY_NAMESPACE" &>/dev/null || oc create secret tls "$TLS_SECRET_NAME" \
  --cert="$temp_dir"/hc.crt --key="$temp_dir"/hc.key -n "$REGISTRY_NAMESPACE"

# Create the htpasswd auth for the image registry by using a temporary directory for REGISTRY_USERNAME and REGISTRY_PASSWORD
tempfile=$(mktemp)
htpasswd -Bbn "${REGISTRY_USERNAME}" "${REGISTRY_PASSWORD}" > "${tempfile}"
oc get secret htpasswd -n "$REGISTRY_NAMESPACE" &>/dev/null || oc create secret generic htpasswd --from-file=htpasswd="${tempfile}" -n "$REGISTRY_NAMESPACE"
rm -f "${tempfile}"

# Create the image registry deployment service and route
cat <<EOF | oc apply -f -
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: "${REGISTRY_NAME}"
  namespace: "${REGISTRY_NAMESPACE}"
  labels:
    app: "${REGISTRY_NAME}"
spec:
  replicas: 1
  selector:
    matchLabels:
      app: "${REGISTRY_NAME}"
  template:
    metadata:
      labels:
        app: "${REGISTRY_NAME}"
    spec:
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      containers:
      - name: "${REGISTRY_NAME}"
        image: "${REGISTRY_IMAGE}"
        ports:
        - containerPort: 5000
        env:
        - name: REGISTRY_HTTP_TLS_CERTIFICATE
          value: "/tls/tls.crt"
        - name: REGISTRY_HTTP_TLS_KEY
          value: "/tls/tls.key"
        - name: REGISTRY_AUTH_HTPASSWD_PATH
          value: "/auth/htpasswd"
        - name: REGISTRY_AUTH_HTPASSWD_REALM
          value: "Registry Realm"
        - name: REGISTRY_AUTH
          value: "htpasswd"
        imagePullPolicy: "IfNotPresent"
        resources:
          requests:
            cpu: "500m"
            memory: "500Mi"
        volumeMounts:
        - name: tls-certs
          mountPath: /tls
          readOnly: true
        - name: htpasswd-auth
          mountPath: /auth
          readOnly: true
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            drop:
            - ALL
      volumes:
      - name: htpasswd-auth
        secret:
          secretName: htpasswd
      - name: tls-certs
        secret:
          secretName: "$TLS_SECRET_NAME"
---
apiVersion: v1
kind: Service
metadata:
  name: "${REGISTRY_NAME}"
  namespace: "${REGISTRY_NAMESPACE}"
  labels:
    app: "${REGISTRY_NAME}"
spec:
  ports:
    - port: 5000
  selector:
    app: "${REGISTRY_NAME}"
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: "${REGISTRY_NAME}"
  namespace: "${REGISTRY_NAMESPACE}"
spec:
  to:
    kind: Service
    name: "${REGISTRY_NAME}"
  tls:
    termination: passthrough
EOF

# retry_until_success <retries> <sleep_time> <function_name> [args...]
# - retries       : max number of attempts
# - sleep_time    : seconds between attempts
# - func          : the function to be called or a sub shell call
function retry_until_success() {
    local retries="$1"
    local sleep_time="$2"
    shift 2   # drop retries and sleep_time
    for i in $(seq 1 "$retries"); do
        echo "Attempt $i/$retries: running $*"
        if "$@"; then
            echo "Success on attempt $i"
            return 0
        fi
        echo "Failed attempt $i, retrying in $sleep_time seconds..."
        sleep "$sleep_time"
    done
    echo "$* did not succeed after $retries attempts"
    return 1
}

function check_pods_running() {
    pods=$(oc get pods -l "app=$REGISTRY_NAME" -n "$REGISTRY_NAMESPACE" -o jsonpath='{.items[*].metadata.name}')
    for pod in $pods; do
        if ! oc get pod $pod -n ${REGISTRY_NAMESPACE} -o jsonpath='{.status.phase}'|grep Running; then
            return 1
        fi
    done
    return 0
}

retry_until_success 20 5 check_pods_running

REG_ROUTE=$(oc get route "$REGISTRY_NAME" -n "$REGISTRY_NAMESPACE" -o=jsonpath='{.spec.host}')

# Mirror the SRC_IMG to the target image registry for testing
SRC_IMG="${SRC_IMG:-quay.io/openshifttest/busybox:51055}"
IMAGE_PATH="${SRC_IMG#*/}"
DST_IMG="${REG_ROUTE}/${REGISTRY_NAMESPACE}/${IMAGE_PATH}"

oc registry login --registry="$REG_ROUTE" --auth-basic="${REGISTRY_USERNAME}:${REGISTRY_PASSWORD}" --to="${temp_dir}"/authfile --insecure -n "$REGISTRY_NAMESPACE"
oc image mirror "$SRC_IMG" "$DST_IMG" --insecure -a "${temp_dir}"/authfile --keep-manifest-list=true --filter-by-os=".*"

# record the registry information: route, user, pass, namespace
cat >>"$SHARED_DIR"/image_registry.ini <<EOF
route: $REG_ROUTE
username: $REGISTRY_USERNAME
password: $REGISTRY_PASSWORD
namespace: $REGISTRY_NAMESPACE
src_image: $SRC_IMG
dst_image: $DST_IMG
EOF

rm -rf "${temp_dir}"
