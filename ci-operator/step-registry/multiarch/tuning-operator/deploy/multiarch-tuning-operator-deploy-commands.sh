#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

trap 'FRC=$?; createMTOJunit; debug' EXIT TERM

# Print deployments, pods, nodes for debug purpose
function debug() {
    if (( FRC != 0 )); then
        set +e
        oc image info --show-multiarch "${OO_BUNDLE}" |& tee "${ARTIFACT_DIR}/image-info.txt"
        for r in pods deployments events subscriptions clusterserviceversions clusterpodplacementconfigs; do
          oc get ${r} -n "${NAMESPACE}" -o yaml > "${ARTIFACT_DIR}/${r}.yaml"
          oc describe ${r} -n "${NAMESPACE}" |& tee "${ARTIFACT_DIR}/${r}.txt"
          oc get ${r} -n "${NAMESPACE}" -o wide
        done
    fi
}

# Generate the Junit for MTO
function createMTOJunit() {
    echo "Generating the Junit for MTO"
    filename="import-MTO"
    testsuite="MTO"
    if (( FRC == 0 )); then
        cat >"${ARTIFACT_DIR}/${filename}.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="${testsuite}" failures="0" errors="0" skipped="0" tests="1" time="1">
  <testcase name="OCP-00001:lwan:Installing Multiarch Tuning Operator should succeed"/>
</testsuite>
EOF
    else
        cat >"${ARTIFACT_DIR}/${filename}.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="${testsuite}" failures="1" errors="0" skipped="0" tests="1" time="1">
  <testcase name="OCP-00001:lwan:Installing Multiarch Tuning Operator should succeed">
    <failure message="">Installing Multiarch Tuning Operator failed</failure>
  </testcase>
</testsuite>
EOF
    fi
}

function wait_created() {
    # wait 10 mins
    for _ in $(seq 1 60); do
        if oc get "${@}" | grep -v -q "No resources found"; then
            return 0
        fi
        sleep 10
    done
    return 1
}

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
    echo "Setting proxy"
    source "${SHARED_DIR}/proxy-conf.sh"
fi

# Deploy Multiarch Tuning Operator
NAMESPACE="openshift-multiarch-tuning-operator"
if [[ "$MTO_OPERATOR_INSTALL_METHOD" != "catalog" && "$MTO_OPERATOR_INSTALL_METHOD" != "bundle" ]]; then
  echo "MTO_OPERATOR_INSTALL_METHOD must be either catalog or bundle, current value is $MTO_OPERATOR_INSTALL_METHOD"
  exit 1
fi
if [[ "$MTO_OPERATOR_INSTALL_METHOD" == "catalog" ]]; then
    KUSTOMIZE_ENV="${KUSTOMIZE_ENV:-prow}"
fi
if [[ -n "$KUSTOMIZE_ENV" ]]; then
    mkdir -p /tmp/kustomization
    cat <<EOF > /tmp/kustomization/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - github.com/openshift/multiarch-tuning-operator/deploy/envs/${KUSTOMIZE_ENV}
patches:
EOF
    if [[ -n "$CATALOG_IMAGE_OVERRIDE" ]]; then
        cat <<EOF >> /tmp/kustomization/kustomization.yaml
  - target:
      group: operators.coreos.com
      version: v1alpha1
      kind: CatalogSource
      name: multiarch-tuning-operator-catalog
    patch: |-
      - op: replace
        path: /spec/image
        value: ${CATALOG_IMAGE_OVERRIDE}
EOF
    fi
    if [[ -n "$SUBSCRIPTION_CHANNEL_OVERRIDE" ]]; then
        cat <<EOF >> /tmp/kustomization/kustomization.yaml
  - target:
      group: operators.coreos.com
      version: v1alpha1
      kind: Subscription
      name: openshift-multiarch-tuning-operator
      namespace: openshift-multiarch-tuning-operator
    patch: |-
      - op: replace
        path: /spec/channel
        value: ${SUBSCRIPTION_CHANNEL_OVERRIDE}
EOF
    fi
    echo -e "For debug: show kustomization.yaml\n$(cat /tmp/kustomization/kustomization.yaml)"
    oc apply -k /tmp/kustomization
fi
if [[ "$MTO_OPERATOR_INSTALL_METHOD" == "bundle" ]]; then 
    oc create namespace ${NAMESPACE}
    OO_BUNDLE=registry.ci.openshift.org/origin/multiarch-tuning-op-bundle:main
    operator-sdk run bundle --timeout=10m --security-context-config restricted -n $NAMESPACE "${BUNDLE_OVERRIDE:-${OO_BUNDLE}}"
fi
echo "Waiting for multiarch-tuning-operator"
wait_created deployments -n ${NAMESPACE} -l app.kubernetes.io/part-of=multiarch-tuning-operator
oc wait deployments -n ${NAMESPACE} \
  -l app.kubernetes.io/part-of=multiarch-tuning-operator \
  --for=condition=Available=True
wait_created pods -n ${NAMESPACE} -l control-plane=controller-manager
oc wait pods -n ${NAMESPACE} \
  -l control-plane=controller-manager \
  --for=condition=Ready=True
