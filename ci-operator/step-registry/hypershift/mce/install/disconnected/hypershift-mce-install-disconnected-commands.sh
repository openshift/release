#!/bin/bash

set -ex

echo "************ MCE install disconnected command ************"

source "${SHARED_DIR}/packet-conf.sh"

scp "${SSHOPTS[@]}" "/etc/acm-d-mce-quay-pull-credentials/acm_d_mce_quay_username" "root@${IP}:/home/acm_d_mce_quay_username"
scp "${SSHOPTS[@]}" "/etc/acm-d-mce-quay-pull-credentials/acm_d_mce_quay_pullsecret" "root@${IP}:/home/acm_d_mce_quay_pullsecret"
scp "${SSHOPTS[@]}" "/etc/acm-d-mce-quay-pull-credentials/registry_quay.json" "root@${IP}:/home/registry_quay.json"
scp "${SSHOPTS[@]}" "${CLUSTER_PROFILE_DIR}/pull-secret" "root@${IP}:/home/pull-secret"
scp "${SSHOPTS[@]}" "/var/run/vault/mirror-registry/registry_brew.json" "root@${IP}:/home/registry_brew.json"

# shellcheck disable=SC2087
ssh "${SSHOPTS[@]}" "root@${IP}" bash -s -- "$MCE_VERSION" "$MCE_INDEX_IMAGE" << 'EOF' |& sed -e 's/.*auths\{0,1\}".*/*** PULL_SECRET ***/g'
MCE_VERSION="${1}"
MCE_INDEX_IMAGE="${2}"

set -xeo pipefail

echo "1. Get mirror registry"
mirror_registry=$(oc get imagecontentsourcepolicy -o json | jq -r '.items[].spec.repositoryDigestMirrors[0].mirrors[0]')
mirror_registry=${mirror_registry%%/*}
if [[ $mirror_registry == "" ]] ; then
    echo "Warning: Can not find the mirror registry, abort !!!"
    exit 1
fi
echo "mirror registry is ${mirror_registry}"

echo "2: Set registry credentials"
yum install -y skopeo
oc -n openshift-config extract secret/pull-secret --to="/tmp" --confirm
set +x
mirror_token=$(cat "/tmp/.dockerconfigjson" | jq -r --arg var1 "${mirror_registry}" '.auths[$var1]["auth"]'|base64 -d)
skopeo login "${mirror_registry}" -u "${mirror_token%:*}" -p "${mirror_token#*:}"
BREW_USER=$(cat "/home/registry_brew.json" | jq -r '.user')
BREW_PASSWORD=$(cat "/home/registry_brew.json" | jq -r '.password')
skopeo login -u "$BREW_USER" -p "$BREW_PASSWORD" brew.registry.redhat.io
ACM_D_QUAY_USER=$(cat /home/acm_d_mce_quay_username)
ACM_D_QUAY_PASSWORD=$(cat /home/acm_d_mce_quay_pullsecret)
skopeo login quay.io:443/acm-d -u "${ACM_D_QUAY_USER}" -p "${ACM_D_QUAY_PASSWORD}"
REGISTRY_REDHAT_IO_USER=$(cat /home/pull-secret | jq -r '.auths."registry.redhat.io".auth' | base64 -d | cut -d ':' -f 1)
REGISTRY_REDHAT_IO_PASSWORD=$(cat /home/pull-secret | jq -r '.auths."registry.redhat.io".auth' | base64 -d | cut -d ':' -f 2)
skopeo login registry.redhat.io -u "${REGISTRY_REDHAT_IO_USER}" -p "${REGISTRY_REDHAT_IO_PASSWORD}"
set -x

echo "3: skopeo copy docker://${MCE_INDEX_IMAGE} oci:///home/mce-local-catalog --remove-signatures"

#### workaround for https://issues.redhat.com/browse/OCPBUGS-31536 when executed on RHEL8 hosts
# TODO: remove this only once https://issues.redhat.com/browse/OCPBUGS-31536 is properly fixed
# replace the opm tool in the index image with the latest upstream one which is statically linked
cat <<END |tee "/home/Dockerfile.mce_index_image_static_opm"
FROM ${MCE_INDEX_IMAGE}
USER root
RUN curl -L "https://github.com/operator-framework/operator-registry/releases/latest/download/linux-$(uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/')-opm" -o /tmp/opm && chmod +x /tmp/opm && mv /tmp/opm /usr/bin/opm && opm version
USER 1001
END

MCE_INDEX_IMAGE="${mirror_registry}/acm-d/iib:mce"
podman build -f /home/Dockerfile.mce_index_image_static_opm -t ${MCE_INDEX_IMAGE}
podman push ${MCE_INDEX_IMAGE}
####

skopeo copy "docker://${MCE_INDEX_IMAGE}" "oci:///home/mce-local-catalog" --remove-signatures

echo "4: get oc-mirror from stable clients"
if [[ ! -f /home/oc-mirror ]]; then
    MIRROR2URL="https://mirror2.openshift.com/pub/openshift-v4"
    # TODO: as for https://issues.redhat.com/browse/OCPBUGS-30859
    # the oc-mirror lost rhel8 compatibility with OCP 4.15.3 release
    # choose the appropriate rhel8/rhel9 binary at runtime once available.
    # Now let's stick the the 4.14 binary as a temporary workaround
    # CLIENTURL="${MIRROR2URL}"/x86_64/clients/ocp/stable
    CLIENTURL="${MIRROR2URL}"/x86_64/clients/ocp/stable-4.14
    ###
    curl -s -k -L "${CLIENTURL}/oc-mirror.tar.gz" -o om.tar.gz && tar -C /home -xzvf om.tar.gz && rm -f om.tar.gz
    if ls /home/oc-mirror > /dev/null ; then
        chmod +x /home/oc-mirror
    else
        echo "Warning, can not find oc-mirror abort !!!"
        exit 1
    fi
fi
/home/oc-mirror version

echo "5. oc-mirror --config /home/imageset-config.yaml docker://${mirror_registry} --oci-registries-config=/home/registry.conf --continue-on-error --skip-missing"

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
    targetCatalog: "acm-d/mce-custom-registry"
    targetTag: "${MCE_VERSION}"
    packages:
    - name: multicluster-engine
END

pushd /home
# cleanup leftovers from previous executions
rm -rf oc-mirror-workspace
/home/oc-mirror --config "/home/imageset-config.yaml" docker://${mirror_registry} --oci-registries-config="/home/registry.conf" --continue-on-error --skip-missing
/home/oc-mirror --config "/home/imageset-config.yaml" docker://${mirror_registry} --oci-registries-config="/home/registry.conf" --continue-on-error --skip-missing
/home/oc-mirror --config "/home/imageset-config.yaml" docker://${mirror_registry} --oci-registries-config="/home/registry.conf" --continue-on-error --skip-missing
popd

echo "6. Create imageconentsourcepolicy and catalogsource"
cat << END | oc apply -f -
apiVersion: operator.openshift.io/v1alpha1
kind: ImageContentSourcePolicy
metadata:
  name: rhacm-repo
spec:
  repositoryDigestMirrors:
  - mirrors:
    - ${mirror_registry}/multicluster-engine
    source: registry.redhat.io/rhacm2
  - mirrors:
    - ${mirror_registry}/rh-osbs/multicluster-engine-mce-operator-bundle
    source: registry-proxy.engineering.redhat.com/rh-osbs/multicluster-engine-mce-operator-bundle
  - mirrors:
    - ${mirror_registry}/rh-osbs/iib
    source: registry-proxy.engineering.redhat.com/rh-osbs/iib
  - mirrors:
    - ${mirror_registry}/multicluster-engine
    source: registry.redhat.io/multicluster-engine
END
cat << END | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: cs-mce-custom-registry
  namespace: openshift-marketplace
spec:
  image: ${mirror_registry}/acm-d/mce-custom-registry:${MCE_VERSION}
  sourceType: grpc
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

echo "* Applying SUBSCRIPTION_CHANNEL stable to multiclusterengine-operator subscription"
oc apply -f - <<END
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: multicluster-engine
  namespace: multicluster-engine
spec:
  channel: stable-${MCE_VERSION}
  installPlanApproval: Automatic
  name: multicluster-engine
  source: cs-mce-custom-registry
  sourceNamespace: openshift-marketplace
END

CSVName=""
for ((i=1; i<=60; i++)); do
  output=$(oc get sub multicluster-engine -n multicluster-engine -o jsonpath='{.status.currentCSV}' >> /dev/null && echo "exists" || echo "not found")
  if [ "$output" != "exists" ]; then
    sleep 2
    continue
  fi
  CSVName=$(oc get sub -n multicluster-engine multicluster-engine -o jsonpath='{.status.currentCSV}')
  if [ "$CSVName" != "" ]; then
    break
  fi
  sleep 10
done

_apiReady=0
echo "* Using CSV: ${CSVName}"
for ((i=1; i<=20; i++)); do
  sleep 30
  output=$(oc get csv -n multicluster-engine $CSVName -o jsonpath='{.status.phase}' >> /dev/null && echo "exists" || echo "not found")
  if [ "$output" != "exists" ]; then
    continue
  fi
  phase=$(oc get csv -n multicluster-engine $CSVName -o jsonpath='{.status.phase}')
  if [ "$phase" == "Succeeded" ]; then
    _apiReady=1
    break
  fi
  echo "Waiting for CSV to be ready"
done

if [ $_apiReady -eq 0 ]; then
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
echo "Disable HIVE component in MCE"
oc patch mce multiclusterengine-sample --type=merge -p '{"spec":{"overrides":{"components":[{"name":"hive","enabled": false}]}}}'

set -x
EOF

if [ ! -f "${SHARED_DIR}/mirror_registry_url" ] ; then
  oc get imagecontentsourcepolicy -o json | jq -r '.items[].spec.repositoryDigestMirrors[0].mirrors[0]' | head -n 1 | cut -d '/' -f 1 > "${SHARED_DIR}/mirror_registry_url"
fi
