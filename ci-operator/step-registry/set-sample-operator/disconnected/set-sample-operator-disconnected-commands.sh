#!/bin/bash

set -e
set -u
set -o pipefail

function run_command() {
    local CMD="$1"
    echo "Running Command: ${CMD}"
    eval "${CMD}"
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

function mirror_tag_images () {
    echo "quay.io/openshift-qe-optional-operators/ocp4-index:latest=MIRROR_REGISTRY_PLACEHOLDER/openshift-qe-optional-operators/ocp4-index:latest
registry.redhat.io/ubi8/ruby-30:latest=MIRROR_REGISTRY_PLACEHOLDER/ubi8/ruby-30:latest
registry.redhat.io/ubi8/ruby-27:latest=MIRROR_REGISTRY_PLACEHOLDER/ubi8/ruby-27:latest
registry.redhat.io/ubi7/ruby-27:latest=MIRROR_REGISTRY_PLACEHOLDER/ubi7/ruby-27:latest
registry.redhat.io/rhscl/ruby-25-rhel7:latest=MIRROR_REGISTRY_PLACEHOLDER/rhscl/ruby-25-rhel7:latest
registry.redhat.io/rhscl/mysql-80-rhel7:latest=MIRROR_REGISTRY_PLACEHOLDER/rhscl/mysql-80-rhel7:latest
registry.redhat.io/rhel8/mysql-80:latest=MIRROR_REGISTRY_PLACEHOLDER/rhel8/mysql-80:latest
registry.redhat.io/rhel8/httpd-24:latest=MIRROR_REGISTRY_PLACEHOLDER/rhel8/httpd-24:latest
quay.io/openshifttest/osus-graph-data-container:latest=MIRROR_REGISTRY_PLACEHOLDER/openshifttest/osus-graph-data-container:latest
" > /tmp/tag_images_list

    run_command "oc extract secret/pull-secret -n openshift-config --confirm --to /tmp"; ret=$?
    if [[ $ret -eq 0 ]]; then
        echo "Get the cluster global pull secret successfully."
    else
        echo "!!! Fail to get the cluster global pull secret"
        return 1
    fi

    sed -i "s/MIRROR_REGISTRY_PLACEHOLDER/${REGISTRY_HOST}:5000/g" "/tmp/tag_images_list"
    run_command "cat /tmp/tag_images_list"
    run_command "oc image mirror -f \"/tmp/tag_images_list\"  --insecure=true -a \"/tmp/.dockerconfigjson\" --skip-missing=true --skip-verification=true --keep-manifest-list=true --filter-by-os='.*'"; ret=$?
    if [[ $ret -eq 0 ]]; then
        echo "Mirror tag images to the Proxy registry successfully."
    else
        echo "!!! Fail to mirror tag images to the Proxy registry"
        run_command "cat /tmp/.dockerconfigjson"
        return 1
    fi
}

run_command "oc get config.samples.operator.openshift.io cluster"; ret=$?
if [[ $ret -eq 0 ]]; then
    echo "The Sample operator installed in the cluster, continue..."
else
    echo "!!! the sample operaro NOT installed in the cluster, skip..."
    return 0
fi

MIRROR_PROXY_REGISTRY=`head -n 1 "${SHARED_DIR}/mirror_registry_url"`
# get registry host name, no port
REGISTRY_HOST=`echo ${MIRROR_PROXY_REGISTRY} | cut -d \: -f 1`
mirror_tag_images
config_samples_operator
