#!/bin/bash

set -ex

echo "************ MCE install disconnected command ************"

source "${SHARED_DIR}/packet-conf.sh"

scp "${SSHOPTS[@]}" "/etc/acm-d-mce-quay-pull-credentials/acm_d_mce_quay_username" "root@${IP}:/home/acm_d_mce_quay_username"
scp "${SSHOPTS[@]}" "/etc/acm-d-mce-quay-pull-credentials/acm_d_mce_quay_pullsecret" "root@${IP}:/home/acm_d_mce_quay_pullsecret"
scp "${SSHOPTS[@]}" "/etc/acm-d-mce-quay-pull-credentials/registry_quay.json" "root@${IP}:/home/registry_quay.json"
scp "${SSHOPTS[@]}" "/var/run/vault/mirror-registry/registry_brew.json" "root@${IP}:/home/registry_brew.json"
echo "$MCE_INDEX_IMAGE" > /tmp/mce-index-image
scp "${SSHOPTS[@]}" "/tmp/mce-index-image" "root@${IP}:/home/mce-index-image"
echo "$MCE_VERSION" > /tmp/mce-version
scp "${SSHOPTS[@]}" "/tmp/mce-version" "root@${IP}:/home/mce-version"

# shellcheck disable=SC2087
ssh "${SSHOPTS[@]}" "root@${IP}" bash - << EOF
set -xeo pipefail

echo "1. Update pull-secret"
QUAY_USERNAME=\$(cat /home/acm_d_mce_quay_username)
QUAY_PASSWORD=\$(cat /home/acm_d_mce_quay_pullsecret)
oc get secret pull-secret -n openshift-config -o json | jq -r '.data.".dockerconfigjson"' | base64 -d > /tmp/global-pull-secret.json
QUAY_AUTH=\$(echo -n "\${QUAY_USERNAME}:\${QUAY_PASSWORD}" | base64 -w 0)
jq --arg QUAY_AUTH "\$QUAY_AUTH" '.auths += {"quay.io:443": {"auth":\$QUAY_AUTH,"email":""}}' /tmp/global-pull-secret.json > /tmp/global-pull-secret.json.tmp
mv /tmp/global-pull-secret.json.tmp /tmp/global-pull-secret.json
oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson=/tmp/global-pull-secret.json
rm /tmp/global-pull-secret.json
sleep 60
oc wait mcp master worker --for condition=updated --timeout=20m

echo "2. Get mirror registry"
mirror_registry=\$(oc get imagecontentsourcepolicy -o json | jq -r '.items[].spec.repositoryDigestMirrors[0].mirrors[0]')
mirror_registry=\${mirror_registry%%/*}
if [[ \$mirror_registry == "" ]] ; then
    echo "Warning: Can not find the mirror registry, abort !!!"
    exit 0
fi
echo "mirror registry is \${mirror_registry}"

echo "3: Set registry credentials"
yum install -y skopeo
oc -n openshift-config extract secret/pull-secret --to="/tmp" --confirm
mirror_token=\$(cat "/tmp/.dockerconfigjson" | jq -r --arg var1 "\${mirror_registry}" '.auths[\$var1]["auth"]'|base64 -d)
skopeo login "\${mirror_registry}" -u "\${mirror_token%:*}" -p "\${mirror_token#*:}"
BREW_USER=\$(cat "/home/registry_brew.json" | jq -r '.user')
BREW_PASSWORD=\$(cat "/home/registry_brew.json" | jq -r '.password')
skopeo login -u "\$BREW_USER" -p "\$BREW_PASSWORD" brew.registry.redhat.io
ACM_D_QUAY_USER=\$(cat /home/acm_d_mce_quay_username)
ACM_D_QUAY_PASSWORD=\$(cat /home/acm_d_mce_quay_pullsecret)
skopeo login quay.io:443/acm-d -u "\${ACM_D_QUAY_USER}" -p "\${ACM_D_QUAY_PASSWORD}"

MCE_INDEX_IMAGE=\$(cat /home/mce-index-image)
echo "4: skopeo copy docker://\${MCE_INDEX_IMAGE} oci:///home/mce-local-catalog --remove-signatures"
skopeo copy "docker://\${MCE_INDEX_IMAGE}" "oci:///home/mce-local-catalog" --remove-signatures

echo "5. extract oc-mirror from image oc-mirror:v4.13.9"
QUAY_USER=\$(cat "/home/registry_quay.json" | jq -r '.user')
QUAY_PASSWORD=\$(cat "/home/registry_quay.json" | jq -r '.password')
skopeo login quay.io -u "\${QUAY_USER}" -p "\${QUAY_PASSWORD}"
oc_mirror_image="quay.io/openshift-release-dev/ocp-v4.0-art-dev@sha256:278b6167e214992b2a40dd2fb44e8588f4a9ef100a70ec20cada58728350dd02"
oc image extract \$oc_mirror_image --path /usr/bin/oc-mirror:/home --confirm
if ls /home/oc-mirror >/dev/null ;then
    chmod +x /home/oc-mirror
else
    echo "Warning, can not find oc-mirror abort !!!"
    exit 1
fi

echo "6. oc-mirror --config /home/imageset-config.yaml docker://\${mirror_registry} --oci-registries-config=/home/registry.conf --continue-on-error --skip-missing"
catalog_image="acm-d/mce-custom-registry"
catalog_tag=\$(cat "/home/mce-version")

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
    targetTag: "\${catalog_tag}"
    packages:
    - name: multicluster-engine
END

pushd /home
/home/oc-mirror --config "/home/imageset-config.yaml" docker://\${mirror_registry}  --include-local-oci-catalogs --oci-registries-config="/home/registry.conf" --continue-on-error --skip-missing
if [[ "$?" != "0" ]] ;then
    echo "Warning, mirror failed, abort !!!"
    popd
    exit 0
fi
popd

set -x
EOF


xxxxx




#opm alpha list bundles registry-proxy.engineering.redhat.com/rh-osbs/iib:575405 multicluster-engine | grep "2.4" | tail -n 1 | awk 'END {print $NF}'
#
#
#oc apply -f - <<EOF
#apiVersion: operators.coreos.com/v1alpha1
#kind: CatalogSource
#metadata:
#  name: acm-brew-iib
#  namespace: openshift-marketplace
#spec:
#  sourceType: grpc
#  image: brew.registry.redhat.io/rh-osbs/iib:556458
#  displayName: ACM Brew iib 556458
#  publisher: grpc
#EOF
#
#oc apply -f - <<EOF
#apiVersion: operators.coreos.com/v1
#kind: OperatorGroup
#metadata:
#  name: default
#  namespace: multicluster-engine
#spec:
#  targetNamespaces:
#  - multicluster-engine
#EOF