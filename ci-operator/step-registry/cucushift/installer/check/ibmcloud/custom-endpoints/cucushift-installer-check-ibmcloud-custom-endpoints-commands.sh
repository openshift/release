#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

DEFAULT_PRIVATE_ENDPOINTS="${SHARED_DIR}/eps_default.json"

function get_service_endpoint() {
    local service_name=$1
    local service_endpoint=$2
    if [[ "$service_endpoint" == "DEFAULT_ENDPOINT" ]]; then
        service_endpoint=$(jq -r --arg s "${service_name}" '.[$s] // ""' "${DEFAULT_PRIVATE_ENDPOINTS}")
    fi
    echo "${service_endpoint}"
}

function isPreVersion() {
  local required_ocp_version="$1"
  local isPre
  version=$(oc version -o json | jq -r '.openshiftVersion' | cut -d '.' -f1,2)
  echo "get ocp version: ${version}"

  isPre=0
  if [ -n "${version}" ] && [ "$(printf '%s\n' "${required_ocp_version}" "${version}" | sort --version-sort | head -n1)" = "${required_ocp_version}" ]; then
    isPre=1
  fi
  return $isPre
}

function check_ep_names() {
    local isPreVer="$1"
    local output expString
    output=$(openshift-install explain installconfig.platform.ibmcloud.serviceEndpoints)
    if [[ "${isPreVer}" == "True" ]]; then
        expString='Valid Values: "COS","DNSServices","GlobalCatalog","GlobalSearch","GlobalTagging","HyperProtect","IAM","KeyProtect","ResourceController","ResourceManager","VPC"'
    else
        expString='Valid Values: "CIS","COS","COSConfig","DNSServices","GlobalCatalog","GlobalSearch","GlobalTagging","HyperProtect","IAM","KeyProtect","ResourceController","ResourceManager","VPC"'
    fi
    if ! [[ ${output} == *"${expString}"* ]]; then
        echo "ERROR: Unexpected explain installconfig.platform.ibmcloud.serviceEndpoints: - ${output} "
        if [[ "${isPreVer}" == "True" ]]; then
            echo "OCPBUGS-44943 (openshift explain installconfig.platform.ibmcloud.serviceEndpoints list new ep name of 4.18 in the previous version ) not block the test"
            return 0
        fi
        return 1
    else
        echo "Check installconfig.platform.ibmcloud.serviceEndpoints passed."
        return 0
    fi
}

function check_eps() {
    local epFile url ret src_name service_endpoint url
    ret=0
    epFile="${ARTIFACT_DIR}/eps.json"
    oc get infrastructure -o json | jq -r '.items[0].status.platformStatus.ibmcloud.serviceEndpoints' > ${epFile}
    declare -a srv_array
    readarray -t srv_array < <(jq -r 'keys[]' ${DEFAULT_PRIVATE_ENDPOINTS})
    for srv in "${srv_array[@]}"; do
        src_name="SERVICE_ENDPOINT_${srv}"
        if [[ -n "${!src_name}" ]]; then
            service_endpoint=$(get_service_endpoint "${srv}" "${!src_name}")
            url=$(cat ${epFile} | jq -r --arg n ${srv} '.[] | select (.name==$n) | .url')
            echo "${srv} service_endpoint: [${service_endpoint}] url: [${url}] from the infrastructure."
            if [ -n "$url" ] && [ -n "$service_endpoint" ]; then
                if [[ "$url" != "$service_endpoint" ]]; then
                    echo "ERROR 1: [${srv}] endpoint expected is [${service_endpoint}], but get url [${url}] from the infrastructure!!"
                    ret=$((ret + 1))
                else
                    echo "${srv} custom endpoint check passed"
                fi   
            else
                echo "ERROR: [${srv}] endpoint expected is [${service_endpoint}], get url [${url}] from the infrastructure!!"
                ret=$((ret + 1))
            fi
        else
            echo "WARN:  No custom endpoint is defined for ${srv}"
        fi
    done
    return $ret
}


if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
    source "${SHARED_DIR}/proxy-conf.sh"
fi
export KUBECONFIG=${SHARED_DIR}/kubeconfig

isPreVer="True"
isPreVersion "4.17" || isPreVer="False"
echo "is Pre 4.17 version: ${isPreVer}"

ret=0

if [ -n "$SERVICE_ENDPOINT_COS" ]; then
    service_endpoint=$(get_service_endpoint "COS" $SERVICE_ENDPOINT_COS)
    image_registry_pod=$(oc -n openshift-image-registry get pod -l docker-registry=default --no-headers | awk '{print $1}' | head -1)
    output_from_pod=$(oc -n openshift-image-registry exec ${image_registry_pod} -- env | grep  "REGISTRY_STORAGE_S3_REGIONENDPOINT")
    eval "${output_from_pod}"
    if [[ "$service_endpoint" != "$REGISTRY_STORAGE_S3_REGIONENDPOINT" ]]; then
        echo "ERROR: COS custom endpoint - ${service_endpoint} does not take effect in image-registry deployment - ${REGISTRY_STORAGE_S3_REGIONENDPOINT} !!!"
        ret=$((ret + 1))
    else
        echo "COS custom endpoint check passed"
    fi
else
    echo "WARN: No custom endpoint is defined for COS!"    
fi
echo "checking openshift-install explain installconfig.platform.ibmcloud.serviceEndpoints ..." 
check_ep_names "${isPreVer}" || ret=$((ret + $?))

echo "checking oc get infrastructure ..."
check_eps || ret=$((ret + $?))

exit $ret
