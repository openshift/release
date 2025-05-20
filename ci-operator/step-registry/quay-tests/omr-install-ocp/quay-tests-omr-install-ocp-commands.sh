#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

#check versions
oc version || true
openshift-install version || true
which openshift-install || true

#Check AWS CLI
AWS_ACCESS_KEY_ID=$(cat /var/run/quay-qe-omr-secret/access_key) && export AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY=$(cat /var/run/quay-qe-omr-secret/secret_key) && export AWS_SECRET_ACCESS_KEY
AWS_DEFAULT_REGION="us-west-2" && export AWS_DEFAULT_REGION
aws s3 ls

OMR_PUBLIC_KEY=$(cat /var/run/quay-qe-omr-secret/quaybuilder.pub)

cat "${SHARED_DIR}/new_pull_secret" | jq
registry_ci_openshift_ci_auth=$(cat "${SHARED_DIR}/new_pull_secret" | jq '.auths."registry.ci.openshift.org".auth' | tr -d '"')
cat "${SHARED_DIR}/local_registry_icsp_file.yaml"
OMR_HOST_NAME=$(cat ${SHARED_DIR}/OMR_HOST_NAME)
OCP_NAME="omrocpprowci$RANDOM"

echo ${OMR_HOST_NAME}
echo ${OCP_NAME}

cat >> ${SHARED_DIR}/install-config.yaml << EOF
apiVersion: v1
baseDomain: qe.devcluster.openshift.com 
controlPlane:   
  hyperthreading: Enabled 
  name: master
  platform: {}
  replicas: 3
compute: 
- hyperthreading: Enabled 
  name: worker
  platform: {}
  replicas: 3
metadata:
  name: ${OCP_NAME}
networking:
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  machineNetwork:
  - cidr: 10.0.0.0/16
  networkType: OpenShiftSDN
  serviceNetwork:
  - 172.30.0.0/16
platform:
  aws:
    region: us-west-2
    userTags:
      adminContact: quay
      costCenter: 7536
fips: false 
sshKey: ${OMR_PUBLIC_KEY}
pullSecret: '{"auths":{"${OMR_HOST_NAME}:8443": {"auth": "cXVheTpwYXNzd29yZA==","email": "lzha@redhat.com"}, "registry.ci.openshift.org": {"auth": "${registry_ci_openshift_ci_auth}","email": "lzha@redhat.com"}}}'
additionalTrustBundle: |
$(cat "${SHARED_DIR}/rootCA.pem" | awk '{print "    "$0}')
$(cat "${SHARED_DIR}/install-config-mirrors")
EOF

cat "${SHARED_DIR}/install-config.yaml" || true
cp "${SHARED_DIR}/install-config.yaml" ${ARTIFACT_DIR} || true

cp "${SHARED_DIR}/install-config.yaml" /tmp || true
openshift-install --dir=/tmp create cluster --log-level=debug 
cp /tmp/log-bundle-*.tar.gz ${ARTIFACT_DIR} || true

cp "${SHARED_DIR}/install-config.yaml" /tmp || true
openshift-install --dir=/tmp destroy cluster --log-level=debug || true