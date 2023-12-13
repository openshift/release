#!/bin/bash

set -ex

echo "************ MCE install disconnected command ************"

source "${SHARED_DIR}/packet-conf.sh"

scp "${SSHOPTS[@]}" "/etc/acm-d-mce-quay-pull-credentials/acm_d_mce_quay_username" "root@${IP}:/home/acm_d_mce_quay_username"
scp "${SSHOPTS[@]}" "/etc/acm-d-mce-quay-pull-credentials/acm_d_mce_quay_pullsecret" "root@${IP}:/home/acm_d_mce_quay_pullsecret"
scp "${SSHOPTS[@]}" "/etc/acm-d-mce-quay-pull-credentials/registry_quay.json" "root@${IP}:/home/registry_quay.json"
scp "${SSHOPTS[@]}" "${CLUSTER_PROFILE_DIR}/pull-secret" "root@${IP}:/home/pull-secret"
scp "${SSHOPTS[@]}" "/var/run/vault/mirror-registry/registry_brew.json" "root@${IP}:/home/registry_brew.json"
echo "$MCE_INDEX_IMAGE" > /tmp/mce-index-image
scp "${SSHOPTS[@]}" "/tmp/mce-index-image" "root@${IP}:/home/mce-index-image"

# shellcheck disable=SC2087
ssh "${SSHOPTS[@]}" "root@${IP}" bash - << EOF
set -xeo pipefail

echo "1. Get mirror registry"
mirror_registry=\$(oc get imagecontentsourcepolicy -o json | jq -r '.items[].spec.repositoryDigestMirrors[0].mirrors[0]')
mirror_registry=\${mirror_registry%%/*}
if [[ \$mirror_registry == "" ]] ; then
    echo "Warning: Can not find the mirror registry, abort !!!"
    exit 0
fi
echo "mirror registry is \${mirror_registry}"

echo "2: Set registry credentials"
yum install -y skopeo
oc -n openshift-config extract secret/pull-secret --to="/tmp" --confirm
set +x
mirror_token=\$(cat "/tmp/.dockerconfigjson" | jq -r --arg var1 "\${mirror_registry}" '.auths[\$var1]["auth"]'|base64 -d)
skopeo login "\${mirror_registry}" -u "\${mirror_token%:*}" -p "\${mirror_token#*:}"
BREW_USER=\$(cat "/home/registry_brew.json" | jq -r '.user')
BREW_PASSWORD=\$(cat "/home/registry_brew.json" | jq -r '.password')
skopeo login -u "\$BREW_USER" -p "\$BREW_PASSWORD" brew.registry.redhat.io
ACM_D_QUAY_USER=\$(cat /home/acm_d_mce_quay_username)
ACM_D_QUAY_PASSWORD=\$(cat /home/acm_d_mce_quay_pullsecret)
skopeo login quay.io:443/acm-d -u "\${ACM_D_QUAY_USER}" -p "\${ACM_D_QUAY_PASSWORD}"
REGISTRY_REDHAT_IO_USER=\$(cat /home/pull-secret | jq -r '.auths."registry.redhat.io".auth' | base64 -d | cut -d ':' -f 1)
REGISTRY_REDHAT_IO_PASSWORD=\$(cat /home/pull-secret | jq -r '.auths."registry.redhat.io".auth' | base64 -d | cut -d ':' -f 2)
skopeo login registry.redhat.io -u "\${REGISTRY_REDHAT_IO_USER}" -p "\${REGISTRY_REDHAT_IO_PASSWORD}"
set -x

MCE_INDEX_IMAGE=\$(cat /home/mce-index-image)
echo "3: skopeo copy docker://\${MCE_INDEX_IMAGE} oci:///home/mce-local-catalog --remove-signatures"
skopeo copy "docker://\${MCE_INDEX_IMAGE}" "oci:///home/mce-local-catalog" --remove-signatures

echo "4. extract oc-mirror from image oc-mirror:v4.14.1"
set +x
QUAY_USER=\$(cat "/home/registry_quay.json" | jq -r '.user')
QUAY_PASSWORD=\$(cat "/home/registry_quay.json" | jq -r '.password')
skopeo login quay.io -u "\${QUAY_USER}" -p "\${QUAY_PASSWORD}"
set -x
oc_mirror_image="quay.io/openshift-release-dev/ocp-v4.0-art-dev@sha256:80acc20087bec702fcb2624345f3dda071cd78092e5d3c972d75615b837549de"
oc image extract \$oc_mirror_image --path /usr/bin/oc-mirror:/home --confirm
if ls /home/oc-mirror >/dev/null ;then
    chmod +x /home/oc-mirror
else
    echo "Warning, can not find oc-mirror abort !!!"
    exit 1
fi

echo "5. oc-mirror --config /home/imageset-config.yaml docker://\${mirror_registry} --oci-registries-config=/home/registry.conf --continue-on-error --skip-missing"
catalog_image="acm-d/mce-custom-registry"

cat <<END |tee "/home/registry.conf"
[[registry]]
 location = "registry.redhat.io/rhacm2"
 insecure = true
 blocked = false
 mirror-by-digest-only = false
 [[registry.mirror]]
    location = "quay.io:443/acm-d"
    insecure = true
[[registry]]
 location = "registry.redhat.io/multicluster-engine"
 insecure = true
 blocked = false
 mirror-by-digest-only = false
 [[registry.mirror]]
    location = "quay.io:443/acm-d"
    insecure = true
[[registry]]
 location = "registry.access.redhat.com/openshift4/ose-oauth-proxy"
 insecure = true
 blocked = false
 mirror-by-digest-only = false
 [[registry.mirror]]
    location = "registry.redhat.io/openshift4/ose-oauth-proxy"
    insecure = true
[[registry]]
 location = "registry.stage.redhat.io"
 insecure = true
 blocked = false
 mirror-by-digest-only = false
 [[registry.mirror]]
    location = "brew.registry.redhat.io"
    insecure = true
[[registry]]
 location = "registry-proxy.engineering.redhat.com/rh-osbs"
 insecure = true
 blocked = false
 mirror-by-digest-only = false
 [[registry.mirror]]
    location = "brew.registry.redhat.io/rh-osbs"
    insecure = true
END

cat <<END |tee "/home/imageset-config.yaml"
kind: ImageSetConfiguration
apiVersion: mirror.openshift.io/v1alpha2
mirror:
  operators:
  - catalog: "oci:///home/mce-local-catalog"
    targetCatalog: \${catalog_image}
    targetTag: "2.4"
    packages:
    - name: multicluster-engine
END

pushd /home
/home/oc-mirror --config "/home/imageset-config.yaml" docker://\${mirror_registry} --oci-registries-config="/home/registry.conf" --continue-on-error --skip-missing
popd

echo "6. Create imageconentsourcepolicy and catalogsource"
RESULTS_FILE=\$(find /home/oc-mirror-workspace -type d -name '*results*')
oc apply -f "\$RESULTS_FILE/*.yaml"
cat << END | oc apply -f -
apiVersion: operator.openshift.io/v1alpha1
kind: ImageContentSourcePolicy
metadata:
  name: rhacm-repo
spec:
  repositoryDigestMirrors:
  - mirrors:
    - \${mirror_registry}/multicluster-engine
    source: registry.redhat.io/rhacm2
  - mirrors:
    - \${mirror_registry}/rh-osbs
    source: registry-proxy.engineering.redhat.com/rh-osbs
  - mirrors:
    - \${mirror_registry}/multicluster-engine
    source: registry.redhat.io/multicluster-engine
END
echo "Waiting for the new ImageContentSourcePolicy to be updated on machines"
oc wait clusteroperators/machine-config --for=condition=Upgradeable=true --timeout=15m

echo "7. Install MCE Operator"
oc apply -f - <<END
apiVersion: v1
kind: Namespace
metadata:
  name: multicluster-engine
END

oc apply -f - <<END
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: multicluster-engine-group
  namespace: multicluster-engine
spec:
  targetNamespaces:
    - "multicluster-engine"
END

echo "* Applying SUBSCRIPTION_CHANNEL 2.4 to multiclusterengine-operator subscription"
oc apply -f - <<END
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: multicluster-engine
  namespace: multicluster-engine
spec:
  channel: stable-2.4
  installPlanApproval: Automatic
  name: multicluster-engine
  source: cs-mce-custom-registry
  sourceNamespace: openshift-marketplace
END

CSVName=""
for ((i=1; i<=60; i++)); do
  output=\$(oc get sub multicluster-engine -n multicluster-engine -o jsonpath='{.status.currentCSV}' >> /dev/null && echo "exists" || echo "not found")
  if [ "\$output" != "exists" ]; then
    sleep 2
    continue
  fi
  CSVName=\$(oc get sub -n multicluster-engine multicluster-engine -o jsonpath='{.status.currentCSV}')
  if [ "\$CSVName" != "" ]; then
    break
  fi
  sleep 10
done

_apiReady=0
echo "* Using CSV: \${CSVName}"
for ((i=1; i<=20; i++)); do
  sleep 30
  output=\$(oc get csv -n multicluster-engine \$CSVName -o jsonpath='{.status.phase}' >> /dev/null && echo "exists" || echo "not found")
  if [ "\$output" != "exists" ]; then
    continue
  fi
  phase=\$(oc get csv -n multicluster-engine \$CSVName -o jsonpath='{.status.phase}')
  if [ "\$phase" == "Succeeded" ]; then
    _apiReady=1
    break
  fi
  echo "Waiting for CSV to be ready"
done

if [ \$_apiReady -eq 0 ]; then
  echo "multiclusterengine subscription could not install in the allotted time."
  exit 1
fi
echo "multiclusterengine installed successfully"

oc apply -f - <<END
apiVersion: multicluster.openshift.io/v1
kind: MultiClusterEngine
metadata:
  name: multiclusterengine-sample
spec: {}
END
sleep 60

oc patch mce multiclusterengine-sample --type=merge -p '{"spec":{"overrides":{"components":[{"name":"hypershift-preview","enabled": true}]}}}'
echo "wait for mce to Available"
oc wait --timeout=20m --for=condition=Available MultiClusterEngine/multiclusterengine-sample

oc apply -f - <<END
kind: ConfigMap
apiVersion: v1
metadata:
  name: hypershift-operator-install-flags
  namespace: local-cluster
data:
  installFlagsToAdd: ""
  installFlagsToRemove: "--enable-uwm-telemetry-remote-write"
END
oc apply -f - <<END
apiVersion: cluster.open-cluster-management.io/v1
kind: ManagedCluster
metadata:
  labels:
    local-cluster: "true"
  name: local-cluster
spec:
  hubAcceptsClient: true
  leaseDurationSeconds: 60
END
oc wait --timeout=5m --for=condition=HubAcceptedManagedCluster -n local-cluster ManagedCluster/local-cluster
oc wait --timeout=5m --for=condition=ManagedClusterImportSucceeded -n local-cluster ManagedCluster/local-cluster
oc wait --timeout=5m --for=condition=ManagedClusterConditionAvailable -n local-cluster ManagedCluster/local-cluster
oc wait --timeout=5m --for=condition=ManagedClusterJoined -n local-cluster ManagedCluster/local-cluster
echo "MCE local-cluster is ready!"

set -x
EOF

oc get imagecontentsourcepolicy -o json | jq -r '.items[].spec.repositoryDigestMirrors[0].mirrors[0]' | head -n 1 | cut -d '/' -f 1 > "${SHARED_DIR}/mirror_registry_url"