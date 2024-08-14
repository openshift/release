#!/usr/bin/env bash

set -ex

echo "************ KubeVirt install disconnected command ************"

function ocp_version() {
    oc get clusterversion version -o jsonpath='{.status.desired.version}' | awk -F "." '{print $1"."$2}'
}

CNV_PRERELEASE_VERSION=${CNV_PRERELEASE_VERSION:-$(ocp_version)}
CNV_PRERELEASE_CATALOG_IMAGE=${CNV_PRERELEASE_CATALOG_IMAGE:-quay.io/openshift-cnv/nightly-catalog:${CNV_PRERELEASE_VERSION}}

if [ -z "${CNV_PRERELEASE_VERSION}" ]
then
  CNV_RELEASE_CHANNEL=stable
  CNV_SUBSCRIPTION_SOURCE=redhat-operators
else
  CNV_RELEASE_CHANNEL=nightly-${CNV_PRERELEASE_VERSION}
  CNV_SUBSCRIPTION_SOURCE=cs-nightly-catalog
fi

# The kubevirt tests require wildcard routes to be allowed
oc patch ingresscontroller -n openshift-ingress-operator default --type=json -p '[{ "op": "add", "path": "/spec/routeAdmission", "value": {wildcardPolicy: "WildcardsAllowed"}}]'

# Make the masters schedulable so we have more capacity to run VMs
oc patch scheduler cluster --type=json -p '[{ "op": "replace", "path": "/spec/mastersSchedulable", "value": true }]'

source "${SHARED_DIR}/packet-conf.sh"

scp "${SSHOPTS[@]}" "/etc/cnv-nightly-pull-credentials/openshift_cnv_pullsecret" "root@${IP}:/home/openshift_cnv_pullsecret"
echo "$CNV_PRERELEASE_CATALOG_IMAGE" > /tmp/cnv-prerelease-catalog-image
scp "${SSHOPTS[@]}" "/tmp/cnv-prerelease-catalog-image" "root@${IP}:/home/cnv-prerelease-catalog-image"
echo "$CNV_PRERELEASE_VERSION" > /tmp/cnv-prerelease-version
scp "${SSHOPTS[@]}" "/tmp/cnv-prerelease-version" "root@${IP}:/home/cnv-prerelease-version"


# shellcheck disable=SC2087
ssh "${SSHOPTS[@]}" "root@${IP}" bash - << 'EOF'
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
QUAY_USERNAME=openshift-cnv+openshift_ci
QUAY_PASSWORD=$(cat /home/openshift_cnv_pullsecret)
skopeo login -u "$QUAY_USERNAME" -p "$QUAY_PASSWORD" quay.io/openshift-cnv
set -x

CNV_PRERELEASE_CATALOG_IMAGE=$(cat /home/cnv-prerelease-catalog-image)
CNV_PRERELEASE_VERSION=$(cat /home/cnv-prerelease-version)
# TODO: handle stable when needed
#CNV_CHANNEL="stable"
CNV_CHANNEL="nightly-${CNV_PRERELEASE_VERSION}"

echo "3: skopeo copy docker://${CNV_PRERELEASE_CATALOG_IMAGE} oci:///home/cnv-local-catalog --remove-signatures"
skopeo copy "docker://${CNV_PRERELEASE_CATALOG_IMAGE}" "oci:///home/cnv-local-catalog" --remove-signatures

echo "4: get oc-mirror from stable clients"
if [[ ! -f /home/oc-mirror ]]; then
    MIRROR2URL="https://mirror2.openshift.com/pub/openshift-v4"
    CLIENTURL="${MIRROR2URL}"/x86_64/clients/ocp/stable
    curl -s -k -L "${CLIENTURL}/oc-mirror.tar.gz" -o om.tar.gz && tar -C /home -xzvf om.tar.gz && rm -f om.tar.gz
    if ls /home/oc-mirror > /dev/null ; then
        chmod +x /home/oc-mirror
    else
        echo "Warning, can not find oc-mirror abort !!!"
        exit 1
    fi
fi
/home/oc-mirror version

echo "5: oc-mirror --config /home/imageset-config.yaml docker://${mirror_registry} --oci-registries-config=/home/registry.conf --continue-on-error --skip-missing"
catalog_image="openshift-cnv/nightly-catalog" # TODO: handle stable when needed

cat <<END |tee "/home/registry.conf"
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
storageConfig:
  local:
    path: mirror
mirror:
  operators:
  - catalog: "oci:///home/cnv-local-catalog"
    targetCatalog: ${catalog_image}
    targetTag: "${CNV_PRERELEASE_VERSION}"
    packages:
    - name: kubevirt-hyperconverged
      channels:
      - name: ${CNV_CHANNEL}
END

pushd /home
# try at least 3 times to be sure to get all the images...
/home/oc-mirror --config "/home/imageset-config.yaml" docker://${mirror_registry} --oci-registries-config="/home/registry.conf" --continue-on-error --skip-missing
/home/oc-mirror --config "/home/imageset-config.yaml" docker://${mirror_registry} --oci-registries-config="/home/registry.conf" --continue-on-error --skip-missing
/home/oc-mirror --config "/home/imageset-config.yaml" docker://${mirror_registry} --oci-registries-config="/home/registry.conf" --continue-on-error --skip-missing
popd

echo "6: Create imageconentsourcepolicy and catalogsource"
for d in /home/oc-mirror-workspace/results* ; do sed -i "s|name: operator-0$|name: operator-${d#/home/oc-mirror-workspace/results-}|g" ${d}/imageContentSourcePolicy.yaml; done
find /home/oc-mirror-workspace -type d -name '*results*' -exec oc apply -f {}/*.yaml \;

cat << END | oc apply -f -
apiVersion: operator.openshift.io/v1alpha1
kind: ImageContentSourcePolicy
metadata:
  name: cnv-repo
spec:
  repositoryDigestMirrors:
  - mirrors:
    - ${mirror_registry}/openshift-cnv
    source: quay.io/openshift-cnv
END

cat << END | oc apply -f -
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: redhat-operator-index-0-fixes
spec:
  imageDigestMirrors:
  - mirrors:
    - ${mirror_registry}/openshift4/ose-kube-rbac-proxy
    source: registry.redhat.io/openshift4/ose-kube-rbac-proxy
END

echo "7: Waiting for the new ImageContentSourcePolicy to be updated on machines"
oc wait clusteroperators/machine-config --for=condition=Upgradeable=true --timeout=15m

EOF

if [ ! -f "${SHARED_DIR}/mirror_registry_url" ] ; then
  oc get imagecontentsourcepolicy -o json | jq -r '.items[].spec.repositoryDigestMirrors[0].mirrors[0]' | head -n 1 | cut -d '/' -f 1 > "${SHARED_DIR}/mirror_registry_url"
fi

oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-cnv
EOF

oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-cnv-group
  namespace: openshift-cnv
spec:
  targetNamespaces:
  - openshift-cnv
EOF

cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  labels:
    operators.coreos.com/kubevirt-hyperconverged.openshift-cnv: ''
  name: kubevirt-hyperconverged
  namespace: openshift-cnv
spec:
  channel: ${CNV_RELEASE_CHANNEL}
  installPlanApproval: Automatic
  name: kubevirt-hyperconverged
  source: ${CNV_SUBSCRIPTION_SOURCE}
  sourceNamespace: openshift-marketplace
EOF

sleep 30

oc get subscription -n openshift-cnv kubevirt-hyperconverged -o yaml

RETRIES=30
CSV=
for i in $(seq ${RETRIES}); do
  if [[ -z ${CSV} ]]; then
    CSV=$(oc get subscription -n openshift-cnv kubevirt-hyperconverged -o jsonpath='{.status.installedCSV}')
  fi
  if [[ -z ${CSV} ]]; then
    echo "Try ${i}/${RETRIES}: can't get the CSV yet. Checking again in 30 seconds"
    sleep 30
  fi
  if [[ $(oc get csv -n openshift-cnv ${CSV} -o jsonpath='{.status.phase}') == "Succeeded" ]]; then
    echo "CNV is deployed"
    break
  else
    echo "Try ${i}/${RETRIES}: CNV is not deployed yet. Checking again in 30 seconds"
    sleep 30
  fi
done

if [[ $(oc get csv -n openshift-cnv ${CSV} -o jsonpath='{.status.phase}') != "Succeeded" ]]; then
  echo "Error: Failed to deploy CNV"
  echo "CSV ${CSV} YAML"
  oc get CSV ${CSV} -n openshift-cnv -o yaml
  echo
  echo "CSV ${CSV} Describe"
  oc describe CSV ${CSV} -n openshift-cnv
  exit 1
fi

# Deploy HyperConverged custom resource to complete kubevirt's installation
oc create -f - <<EOF
apiVersion: hco.kubevirt.io/v1beta1
kind: HyperConverged
metadata:
  name: kubevirt-hyperconverged
  namespace: openshift-cnv
spec:
  featureGates:
    enableCommonBootImageImport: false
  logVerbosityConfig:
    kubevirt:
      virtLauncher: 8
      virtHandler: 8
      virtController: 8
      virtApi: 8
      virtOperator: 8
EOF

oc wait hyperconverged -n openshift-cnv kubevirt-hyperconverged --for=condition=Available --timeout=15m

echo "Installing VM console logger in order to aid debugging potential VM boot issues"

ssh "${SSHOPTS[@]}" "root@${IP}" bash - << 'EOF'
set -xeo pipefail

echo "1. Get mirror registry"
mirror_registry=$(oc get imagecontentsourcepolicy -o json | jq -r '.items[].spec.repositoryDigestMirrors[0].mirrors[0]')
mirror_registry=${mirror_registry%%/*}
if [[ $mirror_registry == "" ]] ; then
    echo "Warning: Can not find the mirror registry, abort !!!"
    exit 0
fi
echo "mirror registry is ${mirror_registry}"

echo "2. oc mirror kubevirt-console-debugger image and config ICSP"
oc image mirror quay.io/dvossel/kubevirt-console-debugger:latest ${mirror_registry}/dvossel/kubevirt-console-debugger:latest
cat << END | oc apply -f -
apiVersion: operator.openshift.io/v1alpha1
kind: ImageContentSourcePolicy
metadata:
  name: nfs-repo
spec:
  repositoryDigestMirrors:
  - mirrors:
    - ${mirror_registry}/dvossel
    source: quay.io/dvossel
END

echo "3. deploy nfs provisioner"
oc apply -f https://raw.githubusercontent.com/davidvossel/kubevirt-console-debugger/main/kubevirt-console-logger.yaml

set -x
EOF
