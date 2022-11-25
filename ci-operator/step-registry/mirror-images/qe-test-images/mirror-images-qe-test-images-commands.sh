#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

function run_command() {
    local CMD="$1"
    echo "Running Command: ${CMD}"
    eval "${CMD}"
}

function set_proxy () {
    if test -s "${SHARED_DIR}/proxy-conf.sh" ; then
        echo "setting the proxy"
        # cat "${SHARED_DIR}/proxy-conf.sh"
        echo "source ${SHARED_DIR}/proxy-conf.sh"
        source "${SHARED_DIR}/proxy-conf.sh"
    else
        echo "no proxy setting."
    fi
}

function mirror_tag_images () {
    qe_image="/tmp/mirror-images-list.yaml"
    # Create qe test image list
    echo "quay.io/openshifttest/iperf3:latest=MIRROR_REGISTRY_PLACEHOLDER/openshifttest/iperf3:latest
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
quay.io/openshifttest/resource_consumer:1.2.0=MIRROR_REGISTRY_PLACEHOLDER/openshifttest/resource_consumer:1.2.0
quay.io/openshifttest/ruby-27:1.2.0=MIRROR_REGISTRY_PLACEHOLDER/openshifttest/ruby-27:1.2.0
quay.io/openshifttest/scratch:1.2.0=MIRROR_REGISTRY_PLACEHOLDER/openshifttest/scratch:1.2.0
quay.io/openshifttest/skopeo:1.2.0=MIRROR_REGISTRY_PLACEHOLDER/openshifttest/skopeo:1.2.0
quay.io/openshifttest/sleep:1.2.0=MIRROR_REGISTRY_PLACEHOLDER/openshifttest/sleep:1.2.0
quay.io/openshifttest/squid-proxy:1.2.0=MIRROR_REGISTRY_PLACEHOLDER/openshifttest/squid-proxy:1.2.0
quay.io/openshifttest/ssh-git-server-openshift:1.2.0=MIRROR_REGISTRY_PLACEHOLDER/openshifttest/ssh-git-server-openshift:1.2.0
quay.io/openshifttest/stress:1.2.0=MIRROR_REGISTRY_PLACEHOLDER/openshifttest/stress:1.2.0
quay.io/openshifttest/testssl:1.2.0=MIRROR_REGISTRY_PLACEHOLDER/openshifttest/testssl:1.2.0
quay.io/openshifttest/uiauto-operators-index:1.2.0=MIRROR_REGISTRY_PLACEHOLDER/openshifttest/uiauto-operators-index:1.2.0
quay.io/openshifttest/prometheus-example-app:multiarch=MIRROR_REGISTRY_PLACEHOLDER/openshifttest/prometheus-example-app:multiarch
registry.redhat.io/ubi8/ruby-30:latest=MIRROR_REGISTRY_PLACEHOLDER/ubi8/ruby-30:latest
registry.redhat.io/ubi8/ruby-27:latest=MIRROR_REGISTRY_PLACEHOLDER/ubi8/ruby-27:latest
registry.redhat.io/ubi7/ruby-27:latest=MIRROR_REGISTRY_PLACEHOLDER/ubi7/ruby-27:latest
registry.redhat.io/rhscl/ruby-25-rhel7:latest=MIRROR_REGISTRY_PLACEHOLDER/rhscl/ruby-25-rhel7:latest
registry.redhat.io/rhscl/mysql-80-rhel7:latest=MIRROR_REGISTRY_PLACEHOLDER/rhscl/mysql-80-rhel7:latest
registry.redhat.io/rhel8/mysql-80:latest=MIRROR_REGISTRY_PLACEHOLDER/rhel8/mysql-80:latest
registry.redhat.io/rhel8/httpd-24:latest=MIRROR_REGISTRY_PLACEHOLDER/rhel8/httpd-24:latest
" > "${qe_image}"

# combine custom registry credential and default pull secret
registry_cred=`head -n 1 "/var/run/vault/mirror-registry/registry_creds" | base64 -w 0`
jq --argjson a "{\"${MIRROR_REGISTRY_HOST}\": {\"auth\": \"$registry_cred\"}}" '.auths |= . + $a' "${CLUSTER_PROFILE_DIR}/pull-secret" > "${new_pull_secret}"

# MIRROR IMAGES
sed -i "s/MIRROR_REGISTRY_PLACEHOLDER/${MIRROR_REGISTRY_HOST}/g" "${qe_image}" 
oc image mirror -f "${qe_image}"  --insecure=true -a "${new_pull_secret}" \
 --skip-missing=true --skip-verification=true --keep-manifest-list=true --filter-by-os='.*'
}

# In order to the usr can use the ImageStream that the images stores in the Proxy registry.
# Config the sample operator to retrive the images data from the proxy registry
function config_samples_operator()
{
    echo "# Update samples operator to use ${MIRROR_REGISTRY_HOST} as source registry."
    oc patch config.samples.operator.openshift.io/cluster --patch '{"spec":{"managementState":"Managed","samplesRegistry":'\"${MIRROR_REGISTRY_HOST}\"',"skippedImagestreams":["apicast-gateway","apicurito-ui","dotnet","dotnet-runtime","eap-cd-openshift","eap-cd-runtime-openshift","fis-java-openshift","fis-karaf-openshift","fuse-apicurito-generator","fuse7-console","fuse7-eap-openshift","fuse7-java-openshift","fuse7-karaf-openshift","golang","java","jboss-amq-62","jboss-amq-63","jboss-datagrid65-client-openshift","jboss-datagrid65-openshift","jboss-datagrid71-client-openshift","jboss-datagrid71-openshift","jboss-datagrid72-openshift","jboss-datagrid73-openshift","jboss-datavirt64-driver-openshift","jboss-datavirt64-openshift","jboss-decisionserver64-openshift","jboss-eap64-openshift","jboss-eap70-openshift","jboss-eap71-openshift","jboss-eap72-openjdk11-openshift-rhel8","jboss-eap72-openshift","jboss-eap73-openjdk11-openshift","jboss-eap73-openjdk11-runtime-openshift","jboss-eap73-openshift","jboss-eap73-runtime-openshift","jboss-fuse70-console","jboss-fuse70-eap-openshift","jboss-fuse70-java-openshift","jboss-fuse70-karaf-openshift","jboss-processserver64-openshift","jboss-webserver30-tomcat7-openshift","jboss-webserver30-tomcat8-openshift","jboss-webserver31-tomcat7-openshift","jboss-webserver31-tomcat8-openshift","jboss-webserver50-tomcat9-openshift","jboss-webserver53-openjdk11-tomcat9-openshift","jboss-webserver53-openjdk8-tomcat9-openshift","mariadb","modern-webapp","mongodb","nginx","nodejs","openjdk-11-rhel7","openjdk-11-rhel8","openjdk-8-rhel8","perl","php","postgresql","python","redhat-openjdk18-openshift","redhat-sso70-openshift","redhat-sso71-openshift","redhat-sso72-openshift","redhat-sso73-openshift","redis","rhdm-decisioncentral-rhel8","rhdm-kieserver-rhel8","rhdm-optaweb-employee-rostering-rhel8","rhpam-businesscentral-monitoring-rhel8","rhpam-businesscentral-rhel8","rhpam-kieserver-rhel8","rhpam-smartrouter-rhel8","sso74-openshift-rhel8","ubi8-openjdk-11","ubi8-openjdk-8","jboss-webserver54-openjdk11-tomcat9-openshift-rhel7","jboss-webserver54-openjdk11-tomcat9-openshift-ubi8","jboss-webserver54-openjdk8-tomcat9-openshift-rhel7","jboss-webserver54-openjdk8-tomcat9-openshift-ubi8"]}}' --type=merge
    sleep 2m
    #Samples operator queries istag per 15 mins, it's too slow to update istags. But deleted imagestreams could be re-created directly.
    echo "#To speed up the two imagestreams updating manaully"
    oc delete is ruby httpd -n openshift
}

function set_CA_for_nodes () {
    ca_name=$(oc get image.config.openshift.io/cluster -o=jsonpath="{.spec.additionalTrustedCA.name}")
    if [ $ca_name ] && [ $ca_name = "registry-config" ] ; then
        echo "CA is ready, skip config..."
        return 0
    fi

    # get the QE additional CA
    QE_ADDITIONAL_CA_FILE="/var/run/vault/mirror-registry/client_ca.crt"
    # Configuring additional trust stores for image registry access, details: https://docs.openshift.com/container-platform/4.11/registry/configuring-registry-operator.html#images-configuration-cas_configuring-registry-operator
    run_command "oc create configmap registry-config --from-file=\"${REGISTRY_HOST}..5000\"=${QE_ADDITIONAL_CA_FILE} -n openshift-config"; ret=$?
    if [[ $ret -eq 0 ]]; then
        echo "set the mirror registry ConfigMap successfully."
    else
        echo "!!! fail to set the mirror registry ConfigMap"
        run_command "oc get configmap registry-config -n openshift-config -o yaml"
        return 1
    fi
    run_command "oc patch image.config.openshift.io/cluster --patch '{\"spec\":{\"additionalTrustedCA\":{\"name\":\"registry-config\"}}}' --type=merge"; ret=$?
    if [[ $ret -eq 0 ]]; then
        echo "set additionalTrustedCA successfully."
    else
        echo "!!! Fail to set additionalTrustedCA"
        run_command "oc get image.config.openshift.io/cluster -o yaml"
        return 1
    fi
}

function check_mirror_registry () {
    run_command "oc adm new-project sample-test"
    ret=0
    run_command "oc import-image mytestimage --from=quay.io/openshifttest/busybox@sha256:c5439d7db88ab5423999530349d327b04279ad3161d7596d2126dfb5b02bfd1f --confirm -n sample-test" || ret=$?
    if [[ $ret -eq 0 ]]; then
      echo "mirror registry works well."
      run_command "oc delete ns sample-test"
    else
      echo "mirror registry doesn't work, checking the image.config"
      run_command "oc get image.config cluster -o yaml"
      run_command "oc get configmap registry-config -n openshift-config -o yaml"
      run_command "oc delete ns sample-test"
      return 1
    fi
}

# Create the fixed ICSP for qe test images
function create_settled_icsp () {
    cat <<EOF | oc create -f -
    apiVersion: operator.openshift.io/v1alpha1
    kind: ImageContentSourcePolicy
    metadata:
      name: image-policy-aosqe
    spec:
      repositoryDigestMirrors:
      - mirrors:
        - ${MIRROR_REGISTRY_HOST}/openshifttest
        source: quay.io/openshifttest
      - mirrors:
        - ${MIRROR_REGISTRY_HOST}
        source: registry.redhat.io
EOF
    if [ $? == 0 ]; then
        echo "create the ICSP successfully" 
    else
        echo "!!! fail to create the ICSP"
        return 1
    fi
}


# private mirror registry host
# <public_dns>:<port>
MIRROR_REGISTRY_HOST=`head -n 1 "${SHARED_DIR}/mirror_registry_url"`
if [ ! -f "${SHARED_DIR}/mirror_registry_url" ]; then
    echo "File ${SHARED_DIR}/mirror_registry_url does not exist."
    exit 1
fi
echo "MIRROR_REGISTRY_HOST: $MIRROR_REGISTRY_HOST"
REGISTRY_HOST=`echo ${MIRROR_REGISTRY_HOST} | cut -d \: -f 1`
new_pull_secret="${SHARED_DIR}/new_pull_secret"

# since ci-operator gives steps KUBECONFIG pointing to cluster under test under some circumstances,
# unset KUBECONFIG and proxy setting to ensure this step always interact with the build farm.
unset KUBECONFIG
unset http_proxy
unset https_proxy
mirror_tag_images

# set KUBECONFIG and proxy to interact with cluster
export KUBECONFIG=${SHARED_DIR}/kubeconfig 
set_proxy
set_CA_for_nodes
create_settled_icsp
check_mirror_registry

rm -f "${new_pull_secret}"
