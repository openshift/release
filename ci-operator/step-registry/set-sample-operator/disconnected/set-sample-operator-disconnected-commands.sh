#!/bin/bash

set -e
set -u
set -o pipefail

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

# In order to the usr can use the ImageStream that the images stores in the Proxy registry.
# Config the sample operator to retrive the images data from the proxy registry
function config_samples_operator()
{
    echo "# Update samples operator to use ${MIRROR_PROXY_REGISTRY} as source registry."
    oc patch config.samples.operator.openshift.io/cluster --patch '{"spec":{"managementState":"Managed","samplesRegistry":'\"${MIRROR_PROXY_REGISTRY}\"',"skippedImagestreams":["apicast-gateway","apicurito-ui","dotnet","dotnet-runtime","eap-cd-openshift","eap-cd-runtime-openshift","fis-java-openshift","fis-karaf-openshift","fuse-apicurito-generator","fuse7-console","fuse7-eap-openshift","fuse7-java-openshift","fuse7-karaf-openshift","golang","java","jboss-amq-62","jboss-amq-63","jboss-datagrid65-client-openshift","jboss-datagrid65-openshift","jboss-datagrid71-client-openshift","jboss-datagrid71-openshift","jboss-datagrid72-openshift","jboss-datagrid73-openshift","jboss-datavirt64-driver-openshift","jboss-datavirt64-openshift","jboss-decisionserver64-openshift","jboss-eap64-openshift","jboss-eap70-openshift","jboss-eap71-openshift","jboss-eap72-openjdk11-openshift-rhel8","jboss-eap72-openshift","jboss-eap73-openjdk11-openshift","jboss-eap73-openjdk11-runtime-openshift","jboss-eap73-openshift","jboss-eap73-runtime-openshift","jboss-fuse70-console","jboss-fuse70-eap-openshift","jboss-fuse70-java-openshift","jboss-fuse70-karaf-openshift","jboss-processserver64-openshift","jboss-webserver30-tomcat7-openshift","jboss-webserver30-tomcat8-openshift","jboss-webserver31-tomcat7-openshift","jboss-webserver31-tomcat8-openshift","jboss-webserver50-tomcat9-openshift","jboss-webserver53-openjdk11-tomcat9-openshift","jboss-webserver53-openjdk8-tomcat9-openshift","mariadb","modern-webapp","mongodb","nginx","nodejs","openjdk-11-rhel7","openjdk-11-rhel8","openjdk-8-rhel8","perl","php","postgresql","python","redhat-openjdk18-openshift","redhat-sso70-openshift","redhat-sso71-openshift","redhat-sso72-openshift","redhat-sso73-openshift","redis","rhdm-decisioncentral-rhel8","rhdm-kieserver-rhel8","rhdm-optaweb-employee-rostering-rhel8","rhpam-businesscentral-monitoring-rhel8","rhpam-businesscentral-rhel8","rhpam-kieserver-rhel8","rhpam-smartrouter-rhel8","sso74-openshift-rhel8","ubi8-openjdk-11","ubi8-openjdk-8","jboss-webserver54-openjdk11-tomcat9-openshift-rhel7","jboss-webserver54-openjdk11-tomcat9-openshift-ubi8","jboss-webserver54-openjdk8-tomcat9-openshift-rhel7","jboss-webserver54-openjdk8-tomcat9-openshift-ubi8"]}}' --type=merge
    sleep 2m
    #Samples operator queries istag per 15 mins, it's too slow to update istags. But deleted imagestreams could be re-created directly.
    echo "#To speed up the two imagestreams updating manaully"
    oc delete is ruby httpd -n openshift
}

function set_CA_for_nodes () {
    local ret
    ca_name=$(oc get image.config.openshift.io/cluster -o=jsonpath="{.spec.additionalTrustedCA.name}")
    if [ $ca_name ] && [ $ca_name = "registry-config" ] ; then
        echo "CA is ready, skip config..."
        return 0
    fi

    # get the QE additional CA
    QE_ADDITIONAL_CA_FILE="/var/run/vault/mirror-registry/client_ca.crt"
    REGISTRY_HOST=`echo ${MIRROR_PROXY_REGISTRY} | cut -d \: -f 1`
    # Configuring additional trust stores for image registry access, details: https://docs.openshift.com/container-platform/4.11/registry/configuring-registry-operator.html#images-configuration-cas_configuring-registry-operator
    run_command "oc create configmap registry-config --from-file=\"${REGISTRY_HOST}..5000\"=${QE_ADDITIONAL_CA_FILE} --from-file=\"${REGISTRY_HOST}..6001\"=${QE_ADDITIONAL_CA_FILE} --from-file=\"${REGISTRY_HOST}..6002\"=${QE_ADDITIONAL_CA_FILE}  -n openshift-config"; ret=$?
    if [[ $ret -eq 0 ]]; then
        echo "set the proxy registry ConfigMap successfully."
    else
        echo "!!! fail to set the proxy registry ConfigMap"
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

set_proxy
run_command "oc whoami"
run_command "oc version --client"

ret=0
run_command "oc get config.samples.operator.openshift.io cluster" || ret=$?
if [[ $ret -ne 0 ]]; then
    echo "The Sample operator is not installed in the cluster, skip the test!"
    exit 0
fi

# vmc.mirror-registry.qe.devcluster.openshift.com:5000
MIRROR_PROXY_REGISTRY=`head -n 1 "${SHARED_DIR}/mirror_registry_url"`
echo "MIRROR_PROXY_REGISTRY: ${MIRROR_PROXY_REGISTRY}"
set_CA_for_nodes
config_samples_operator
check_mirror_registry
