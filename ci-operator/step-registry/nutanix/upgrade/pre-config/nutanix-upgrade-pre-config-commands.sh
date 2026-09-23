#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

source "${SHARED_DIR}/nutanix_context.sh"

echo "Creating nutanix-credentials Secret..."
oc apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: nutanix-credentials
  namespace: openshift-cloud-controller-manager
type: Opaque
stringData:
  credentials: "[{
    \"type\":\"basic_auth\",
    \"data\":{
          \"prismCentral\":{
                   \"username\":\"${NUTANIX_USERNAME}\",
                   \"password\":\"${NUTANIX_PASSWORD}\"},
          \"prismElements\":null
          }
    }]"
EOF

echo "Creating cloud-provider-config ConfigMap..."
oc apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: cloud-provider-config
  namespace: openshift-config
data:
  config: "{
      \"prismCentral\": {
          \"address\": \"${NUTANIX_HOST}\",
          \"port\": ${NUTANIX_PORT},
            \"credentialRef\": {
                \"kind\": \"Secret\",
                \"name\": \"nutanix-credentials\",
                \"namespace\": \"openshift-cloud-controller-manager\"
            }
      },
      \"topologyDiscovery\": {
          \"type\": \"Prism\",
          \"topologyCategories\": null
      },
      \"enableCustomLabeling\": true
   }"
EOF

echo "Creating cloud-conf ConfigMap..."
oc apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: cloud-conf
  namespace: openshift-cloud-controller-manager
data:
  cloud.conf: "{
      \"prismCentral\": {
          \"address\": \"${NUTANIX_HOST}\",
          \"port\": ${NUTANIX_PORT},
            \"credentialRef\": {
                \"kind\": \"Secret\",
                \"name\": \"nutanix-credentials\",
                \"namespace\": \"openshift-cloud-controller-manager\"
            }
       },
       \"topologyDiscovery\": {
           \"type\": \"Prism\",
           \"topologyCategories\": null
       },
       \"enableCustomLabeling\": true
     }"
EOF

echo "Patching the cluster Infrastructure Resource..."
oc patch infrastructure cluster --patch '{"spec":{"cloudConfig":{"key":"config","name":"cloud-provider-config"}}}' --type=merge
