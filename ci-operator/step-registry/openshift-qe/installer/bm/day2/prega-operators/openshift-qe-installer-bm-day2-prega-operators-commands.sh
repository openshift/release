#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x
cat /etc/os-release

PREGA_BUILD_SERVER_IP=$(cat ${CLUSTER_PROFILE_DIR}/prega_build_server)
QUAY_ACCESS_TOKEN=$(cat ${CLUSTER_PROFILE_DIR}/prega_quay_auth_token)
SSH_ARGS="-i ${CLUSTER_PROFILE_DIR}/jh_priv_ssh_key -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null"
bastion=$(cat ${CLUSTER_PROFILE_DIR}/address)

get_idms_manifest() {
  echo "Getting the ImageDigestMirrorSet manifest from the PREGA build server"
  QUAY_URL="https://quay.io/api/v1/repository/prega/prega-operator-index/tag/?limit=100&page=1"
  OCP_VERSION=$(oc get clusterversion --no-headers | grep -oE '[0-9]+\.[0-9]+' | head -1 | awk '{print "v"$0}')
  DIGEST=$(curl -s -H "Authorization: Bearer ${QUAY_ACCESS_TOKEN}" ${QUAY_URL} | jq -r --arg tag "$OCP_VERSION" '.tags[] | select(.name == $tag) | .manifest_digest' | head -1)
  OPERATOR_PREGA_VERSION=$(curl -s -H "Authorization: Bearer ${QUAY_ACCESS_TOKEN}" ${QUAY_URL} | jq -r --arg digest "$DIGEST" --arg tag "$OCP_VERSION" '.tags[] | select(.manifest_digest == $digest and .name != $tag) | .name' | sort -u)
  if [[ -z "${OPERATOR_PREGA_VERSION}" ]]; then
    echo "OPERATOR_PREGA_VERSION could not be resolved from Quay; falling back to OCP_VERSION: ${OCP_VERSION}"
    OPERATOR_PREGA_VERSION="${OCP_VERSION}"
  fi
  echo "PREGA Operator Version: ${OPERATOR_PREGA_VERSION} for OCP Version: ${OCP_VERSION}"
  ssh ${SSH_ARGS} root@${bastion} "
    set -e
    set -o pipefail
    curl -k -o /tmp/idms_${OCP_VERSION}.yaml https://${PREGA_BUILD_SERVER_IP}/${OPERATOR_PREGA_VERSION}/imageDigestMirrorSet.yaml
  "
  scp -q ${SSH_ARGS} root@${bastion}:/tmp/idms_${OCP_VERSION}.yaml /tmp/idms_${OCP_VERSION}.yaml

  validate_yaml() {
    local f="$1"
    [[ -s "$f" ]] || return 1
    if command -v yq &>/dev/null; then
      yq eval 'has("kind") and has("apiVersion")' "$f" 2>/dev/null | grep -q '^true$'
    else
      grep -qE '^(apiVersion|kind):' "$f"
    fi
  }

  if ! validate_yaml /tmp/idms_${OCP_VERSION}.yaml; then
    echo "Downloaded /tmp/idms_${OCP_VERSION}.yaml is not valid YAML; falling back to bastion artifact for ${OCP_VERSION}"
    scp -q ${SSH_ARGS} root@${bastion}:/root/prega_artifacts/idms_${OCP_VERSION}.yaml /tmp/idms_${OCP_VERSION}.yaml
    validate_yaml /tmp/idms_${OCP_VERSION}.yaml \
      || { echo "Fallback IDMS /root/prega_artifacts/idms_${OCP_VERSION}.yaml is also invalid or missing"; exit 1; }
  fi

  echo "ImageDigestMirrorSet manifest saved to /tmp/idms_${OCP_VERSION}.yaml"
}

oc config view
oc projects

if [ ${OCP_BUILD} == "dev" ]; then
  echo "Patching OperatorHub to disable all default sources"
  oc patch OperatorHub cluster --type json -p '[{"op": "add", "path": "/spec/disableAllDefaultSources", "value": true}]'

  echo "Getting the existing pull secret from the cluster and merge the prega_auth secret to pull images from quay.io"
  oc get secret pull-secret -n openshift-config -o json | jq -r '.data[".dockerconfigjson"]' | base64 -d > /tmp/existing_pull_secret.json
  cp ${CLUSTER_PROFILE_DIR}/prega_auth /tmp/prega_pull_secret.json
  jq -s '.[0] * .[1]' /tmp/existing_pull_secret.json /tmp/prega_pull_secret.json > /tmp/merged_pull_secret.json
  oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson=/tmp/merged_pull_secret.json
  sleep 300
  oc adm wait-for-stable-cluster --minimum-stable-period=2m --timeout=40m

  echo "Applying the ImageDigestMirrorSet manifest"
  get_idms_manifest
  oc apply -f /tmp/idms_${OCP_VERSION}.yaml
  sleep 300
  oc adm wait-for-stable-cluster --minimum-stable-period=2m --timeout=40m

  echo "Creating CatalogSource for PREGA Operator Index"
  cat << EOF| oc apply -f -
  apiVersion: operators.coreos.com/v1alpha1
  kind: CatalogSource
  metadata:
    name: prega-operator-index
    namespace: openshift-marketplace
  spec:
    image: quay.io/prega/prega-operator-index:${OPERATOR_PREGA_VERSION}
    sourceType: grpc
    displayName: Openshift Pre-GA Operators
EOF

  echo "Waiting for CatalogSource to be ready"
  sleep 300
  kubectl wait --for=jsonpath='{.status.connectionState.lastObservedState}'=READY catalogsource/prega-operator-index -n openshift-marketplace --timeout=300s
  echo "CatalogSource is ready"
  oc get catalogsources.operators.coreos.com -n openshift-marketplace
  oc get packagemanifests.packages.operators.coreos.com

else
  echo "OCP_BUILD is not dev, skipping PREGA Operator Index installation"
fi
