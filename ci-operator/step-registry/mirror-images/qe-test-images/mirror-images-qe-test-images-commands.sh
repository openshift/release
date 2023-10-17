#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

new_pull_secret="${SHARED_DIR}/new_pull_secret"

# private mirror registry host
# <public_dns>:<port>
MIRROR_REGISTRY_HOST=`head -n 1 "${SHARED_DIR}/mirror_registry_url"`
if [ ! -f "${SHARED_DIR}/mirror_registry_url" ]; then
    echo "File ${SHARED_DIR}/mirror_registry_url does not exist."
    exit 1
fi
echo "MIRROR_REGISTRY_HOST: $MIRROR_REGISTRY_HOST"

# since ci-operator gives steps KUBECONFIG pointing to cluster under test under some circumstances,
# unset KUBECONFIG to ensure this step always interact with the build farm.
unset KUBECONFIG

# Create qe test image list
cat <<EOF > "/tmp/mirror-images-list.yaml"
quay.io/openshifttest/iperf3:latest=MIRROR_REGISTRY_PLACEHOLDER/openshifttest/iperf3:latest
quay.io/openshifttest/hello-sdn:1.2.0=MIRROR_REGISTRY_PLACEHOLDER/openshifttest/hello-sdn:1.2.0
quay.io/openshifttest/hello-openshift-fedora:latest=MIRROR_REGISTRY_PLACEHOLDER/openshifttest/hello-openshift-fedora:latest
quay.io/openshifttest/hello-openshift-centos:latest=MIRROR_REGISTRY_PLACEHOLDER/openshifttest/hello-openshift-centos:latest
quay.io/openshifttest/busybox:multiarch=MIRROR_REGISTRY_PLACEHOLDER/openshifttest/busybox:multiarch
quay.io/openshifttest/busybox:51055=MIRROR_REGISTRY_PLACEHOLDER/openshifttest/busybox:51055
quay.io/openshifttest/pod-for-ping:latest=MIRROR_REGISTRY_PLACEHOLDER/openshifttest/pod-for-ping:latest
quay.io/openshifttest/pause:1.2.0=MIRROR_REGISTRY_PLACEHOLDER/openshifttest/pause:1.2.0
quay.io/openshifttest/ui-auto-operators:latest=MIRROR_REGISTRY_PLACEHOLDER/openshifttest/ui-auto-operators:latest
quay.io/openshifttest/header-test-for-reencrypt:latest=MIRROR_REGISTRY_PLACEHOLDER/openshifttest/header-test-for-reencrypt:latest
quay.io/openshifttest/ldap:1.2.0=MIRROR_REGISTRY_PLACEHOLDER/openshifttest/ldap:1.2.0
quay.io/openshifttest/custom-scheduler:4.6-1.2.0=MIRROR_REGISTRY_PLACEHOLDER/openshifttest/custom-scheduler:4.6-1.2.0
quay.io/openshifttest/custom-scheduler:4.7-1.2.0=MIRROR_REGISTRY_PLACEHOLDER/openshifttest/custom-scheduler:4.7-1.2.0
quay.io/openshifttest/custom-scheduler:4.8-1.2.0=MIRROR_REGISTRY_PLACEHOLDER/openshifttest/custom-scheduler:4.8-1.2.0
quay.io/openshifttest/custom-scheduler:4.9-1.2.0=MIRROR_REGISTRY_PLACEHOLDER/openshifttest/custom-scheduler:4.9-1.2.0
quay.io/openshifttest/custom-scheduler:4.10-1.2.0=MIRROR_REGISTRY_PLACEHOLDER/openshifttest/custom-scheduler:4.10-1.2.0
quay.io/openshifttest/alpine:1.2.0=MIRROR_REGISTRY_PLACEHOLDER/openshifttest/alpine:1.2.0
quay.io/openshifttest/base-alpine:1.2.0=MIRROR_REGISTRY_PLACEHOLDER/openshifttest/base-alpine:1.2.0
quay.io/openshifttest/base-fedora:1.2.0=MIRROR_REGISTRY_PLACEHOLDER/openshifttest/base-fedora:1.2.0
quay.io/openshifttest/bench-army-knife:1.2.0=MIRROR_REGISTRY_PLACEHOLDER/openshifttest/bench-army-knife:1.2.0
quay.io/openshifttest/client-cert:1.2.0=MIRROR_REGISTRY_PLACEHOLDER/openshifttest/client-cert:1.2.0
quay.io/openshifttest/deployment-example:v1-1.2.0=MIRROR_REGISTRY_PLACEHOLDER/openshifttest/deployment-example:v1-1.2.0
quay.io/openshifttest/deployment-example:v2-1.2.0=MIRROR_REGISTRY_PLACEHOLDER/openshifttest/deployment-example:v2-1.2.0
quay.io/openshifttest/elasticsearch:1.2.0=MIRROR_REGISTRY_PLACEHOLDER/openshifttest/elasticsearch:1.2.0
quay.io/openshifttest/fedora:1.2.0=MIRROR_REGISTRY_PLACEHOLDER/openshifttest/fedora:1.2.0
quay.io/openshifttest/flexvolume:1.2.0=MIRROR_REGISTRY_PLACEHOLDER/openshifttest/flexvolume:1.2.0
quay.io/openshifttest/fluentd:1.2.0=MIRROR_REGISTRY_PLACEHOLDER/openshifttest/fluentd:1.2.0
quay.io/openshifttest/goflow:1.2.0=MIRROR_REGISTRY_PLACEHOLDER/openshifttest/goflow:1.2.0
quay.io/openshifttest/hello-openshift:fedora-1.2.0=MIRROR_REGISTRY_PLACEHOLDER/openshifttest/hello-openshift:fedora-1.2.0
quay.io/openshifttest/hello-openshift:extended-1.2.0=MIRROR_REGISTRY_PLACEHOLDER/openshifttest/hello-openshift:extended-1.2.0
quay.io/openshifttest/hello-openshift:winc-1.2.0=MIRROR_REGISTRY_PLACEHOLDER/openshifttest/hello-openshift:winc-1.2.0
quay.io/openshifttest/hello-openshift:alt-1.2.0=MIRROR_REGISTRY_PLACEHOLDER/openshifttest/hello-openshift:alt-1.2.0
quay.io/openshifttest/hello-openshift:1.2.0=MIRROR_REGISTRY_PLACEHOLDER/openshifttest/hello-openshift:1.2.0
quay.io/openshifttest/hello-websocket:1.2.0=MIRROR_REGISTRY_PLACEHOLDER/openshifttest/hello-websocket:1.2.0
quay.io/openshifttest/httpbin:1.2.0=MIRROR_REGISTRY_PLACEHOLDER/openshifttest/httpbin:1.2.0
quay.io/openshifttest/httpbin:ssl-1.2.0=MIRROR_REGISTRY_PLACEHOLDER/openshifttest/httpbin:ssl-1.2.0
quay.io/openshifttest/http-header-test:1.2.0=MIRROR_REGISTRY_PLACEHOLDER/openshifttest/http-header-test:1.2.0
quay.io/openshifttest/ip-echo:1.2.0=MIRROR_REGISTRY_PLACEHOLDER/openshifttest/ip-echo:1.2.0
quay.io/openshifttest/iscsi:1.2.0=MIRROR_REGISTRY_PLACEHOLDER/openshifttest/iscsi:1.2.0
quay.io/openshifttest/kafka-initutils:1.2.0=MIRROR_REGISTRY_PLACEHOLDER/openshifttest/kafka-initutils:1.2.0
quay.io/openshifttest/kafka:1.2.0=MIRROR_REGISTRY_PLACEHOLDER/openshifttest/kafka:1.2.0
quay.io/openshifttest/mcast-pod:1.2.0=MIRROR_REGISTRY_PLACEHOLDER/openshifttest/mcast-pod:1.2.0
quay.io/openshifttest/multicast:1.2.0=MIRROR_REGISTRY_PLACEHOLDER/openshifttest/multicast:1.2.0
quay.io/openshifttest/mysql:1.2.0=MIRROR_REGISTRY_PLACEHOLDER/openshifttest/mysql:1.2.0
quay.io/openshifttest/nfs-provisioner:1.2.0=MIRROR_REGISTRY_PLACEHOLDER/openshifttest/nfs-provisioner:1.2.0
quay.io/openshifttest/nfs-server:1.2.0=MIRROR_REGISTRY_PLACEHOLDER/openshifttest/nfs-server:1.2.0
quay.io/openshifttest/nginx-alpine:1.2.0=MIRROR_REGISTRY_PLACEHOLDER/openshifttest/nginx-alpine:1.2.0
quay.io/openshifttest/ociimage:multiarch=MIRROR_REGISTRY_PLACEHOLDER/openshifttest/ociimage:multiarch
quay.io/openshifttest/ociimage-singlearch:x86_64=MIRROR_REGISTRY_PLACEHOLDER/openshifttest/ociimage-singlearch:x86_64
quay.io/openshifttest/ocp-logtest:1.2.0=MIRROR_REGISTRY_PLACEHOLDER/openshifttest/ocp-logtest:1.2.0
quay.io/openshifttest/octest:1.2.0=MIRROR_REGISTRY_PLACEHOLDER/openshifttest/octest:1.2.0
quay.io/openshifttest/operators-index-scaffold:1.2.0=MIRROR_REGISTRY_PLACEHOLDER/openshifttest/operators-index-scaffold:1.2.0
quay.io/openshifttest/origin-cluster-capacity:1.2.0=MIRROR_REGISTRY_PLACEHOLDER/openshifttest/origin-cluster-capacity:1.2.0
quay.io/openshifttest/origin-gitserver:1.2.0=MIRROR_REGISTRY_PLACEHOLDER/openshifttest/origin-gitserver:1.2.0
quay.io/openshifttest/registry:1.2.0=MIRROR_REGISTRY_PLACEHOLDER/openshifttest/registry:1.2.0
quay.io/openshifttest/registry-toomany-request:1.2.0=MIRROR_REGISTRY_PLACEHOLDER/openshifttest/registry-toomany-request:1.2.0
quay.io/openshifttest/ruby-27:1.2.0=MIRROR_REGISTRY_PLACEHOLDER/openshifttest/ruby-27:1.2.0
quay.io/openshifttest/scratch:1.2.0=MIRROR_REGISTRY_PLACEHOLDER/openshifttest/scratch:1.2.0
quay.io/openshifttest/skopeo:1.2.0=MIRROR_REGISTRY_PLACEHOLDER/openshifttest/skopeo:1.2.0
quay.io/openshifttest/sleep:1.2.0=MIRROR_REGISTRY_PLACEHOLDER/openshifttest/sleep:1.2.0
quay.io/openshifttest/squid-proxy:1.2.0=MIRROR_REGISTRY_PLACEHOLDER/openshifttest/squid-proxy:1.2.0
quay.io/openshifttest/ssh-git-server-openshift:1.2.0=MIRROR_REGISTRY_PLACEHOLDER/openshifttest/ssh-git-server-openshift:1.2.0
quay.io/openshifttest/testssl:1.2.0=MIRROR_REGISTRY_PLACEHOLDER/openshifttest/testssl:1.2.0
quay.io/openshifttest/uiauto-operators-index:1.2.0=MIRROR_REGISTRY_PLACEHOLDER/openshifttest/uiauto-operators-index:1.2.0
quay.io/openshifttest/prometheus-example-app:multiarch=MIRROR_REGISTRY_PLACEHOLDER/openshifttest/prometheus-example-app:multiarch
EOF

# combine custom registry credential and default pull secret
registry_cred=`head -n 1 "/var/run/vault/mirror-registry/registry_creds" | base64 -w 0`
# add auth for quay.io/openshifttest for private images
openshifttest_auth_user=$(cat "/var/run/vault/mirror-registry/registry_quay_openshifttest.json" | jq -r '.user')
openshifttest_auth_password=$(cat "/var/run/vault/mirror-registry/registry_quay_openshifttest.json" | jq -r '.password')
openshifttest_registry_auth=`echo -n "${openshifttest_auth_user}:${openshifttest_auth_password}" | base64 -w 0`
jq --argjson a "{\"${MIRROR_REGISTRY_HOST}\": {\"auth\": \"$registry_cred\"},\"quay.io/openshifttest\": {\"auth\": \"${openshifttest_registry_auth}\"}}" '.auths |= . + $a' "${CLUSTER_PROFILE_DIR}/pull-secret" > "${new_pull_secret}"

# MIRROR IMAGES
# Creating ICSP for quay.io/openshifttest is in enable-qe-catalogsource-disconnected step
# Set Node CA for Mirror Registry is in enable-qe-catalogsource-disconnected step
sed -i "s/MIRROR_REGISTRY_PLACEHOLDER/${MIRROR_REGISTRY_HOST}/g" "/tmp/mirror-images-list.yaml" 

# To avoid 409 too many request error, mirroring image one by one
for image in `cat /tmp/mirror-images-list.yaml`
do
    oc image mirror $image  --insecure=true -a "${new_pull_secret}" \
 --skip-missing=true --skip-verification=true --keep-manifest-list=true --filter-by-os='.*'
done

rm -f "${new_pull_secret}"
