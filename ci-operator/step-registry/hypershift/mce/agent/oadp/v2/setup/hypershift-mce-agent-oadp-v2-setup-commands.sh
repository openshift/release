#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
  # Disable xtrace: proxy-conf.sh may export HTTP_PROXY with embedded credentials.
  set +x
  source "${SHARED_DIR}/proxy-conf.sh"
  set -x
fi

OADP_PLUGIN_IMAGE="${OADP_HYPERSHIFT_PLUGIN_IMAGE:-quay.io/konveyor/hypershift-oadp-plugin:latest}"

export KUBECONFIG="${SHARED_DIR}/kubeconfig"

# The hypershift-oadp-rustfs step provides the S3 endpoint, the job-scoped
# credentials and the TLS certificate. Require all of them so a missing or
# partial setup fails here with a clear error instead of a BackupStorageLocation
# timeout with mismatched settings.
endpoint_file="${SHARED_DIR}/minio-endpoint"
credentials_file="${SHARED_DIR}/minio-credentials"
ca_cert_file="${SHARED_DIR}/rustfs-ca.crt"
if [[ ! -s "${endpoint_file}" || ! -s "${credentials_file}" || ! -s "${ca_cert_file}" ]]; then
  echo "RustFS endpoint, credentials or CA certificate missing in ${SHARED_DIR}." >&2
  exit 1
fi
S3_URL="$(<"${endpoint_file}")"

oc create secret generic cloud-credentials -n openshift-adp --from-file=cloud="${credentials_file}"
oc create secret generic rustfs-ca -n openshift-adp --from-file=ca-bundle="${ca_cert_file}"

CLUSTER_NAME=$(cat "${SHARED_DIR}/cluster-name")

# Create the BackupStorageLocation before the DataProtectionApplication so the
# OADP operator aggregates the caCertRef into the velero pod's AWS_CA_BUNDLE
# on its first reconcile.
cat <<EOF | oc apply -f -
apiVersion: velero.io/v1
kind: BackupStorageLocation
metadata:
  name: ${CLUSTER_NAME}
  namespace: openshift-adp
spec:
  provider: aws
  objectStorage:
    bucket: oadp-backup
    prefix: hcp
    caCertRef:
      name: rustfs-ca
      key: ca-bundle
  credential:
    name: cloud-credentials
    key: cloud
  config:
    region: minio
    s3ForcePathStyle: "true"
    s3Url: "${S3_URL}"
    profile: default
EOF

cat <<EOF | oc apply -f -
apiVersion: oadp.openshift.io/v1alpha1
kind: DataProtectionApplication
metadata:
  name: dpa-sample
  namespace: openshift-adp
spec:
  backupImages: false
  configuration:
    nodeAgent:
      enable: true
      uploaderType: kopia
    velero:
      defaultPlugins:
        - openshift
        - aws
        - kubevirt
        - csi
      customPlugins:
        - name: hypershift-oadp-plugin
          image: ${OADP_PLUGIN_IMAGE}
      noDefaultBackupLocation: true
      logLevel: debug
EOF

echo "Waiting for velero Deployment to be ready..."
timeout 5m bash -c 'until oc get deployment/velero -n openshift-adp >/dev/null 2>&1; do sleep 5; done'
oc rollout status deployment/velero -n openshift-adp --timeout=300s

echo "Waiting for node-agent DaemonSet to be ready..."
timeout 10m bash -c 'until oc get daemonset/node-agent -n openshift-adp >/dev/null 2>&1; do sleep 5; done'
oc rollout status daemonset/node-agent -n openshift-adp --timeout=600s

timeout 5m bash -c "until [[ \$(oc get dataProtectionApplication/dpa-sample -n openshift-adp -o jsonpath='{.status.conditions[?(@.type==\"Reconciled\")].status}' 2>/dev/null) == \"True\" ]]; do sleep 15; done"
timeout 5m bash -c "until [[ \$(oc get backupStorageLocation/${CLUSTER_NAME} -n openshift-adp -o jsonpath='{.status.phase}' 2>/dev/null) == \"Available\" ]]; do sleep 15; done"
