#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export AWS_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/.awscred
export AZURE_AUTH_LOCATION=${CLUSTER_PROFILE_DIR}/osServicePrincipal.json
export GCP_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/gce.json
export HOME=/tmp/home
export PATH=/usr/local/go/bin:/usr/libexec/origin:$PATH

# setup proxy
if test -f "${SHARED_DIR}/proxy-conf.sh"
then
    source "${SHARED_DIR}/proxy-conf.sh"
fi

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

# create link for oc to kubectl
mkdir -p "${HOME}"
if ! which kubectl; then
    export PATH=$PATH:$HOME
    ln -s "$(which oc)" ${HOME}/kubectl
fi

# configure go env
export GOPATH=/tmp/goproject
export GOCACHE=/tmp/gocache
export GOROOT=/usr/local/go

# check if the image includes the exectable binary. we prepare it for late usage in case we need to compile it in the step.
if [ -f "/usr/bin/extended-platform-tests" ]; then
    echo "extended-platform-tests already exist, or else please try to compile it"
fi

# configure enviroment for different cluster
case "${CLUSTER_TYPE}" in
gcp)
    export GOOGLE_APPLICATION_CREDENTIALS="${GCP_SHARED_CREDENTIALS_FILE}"
    export KUBE_SSH_USER=core
    mkdir -p ~/.ssh
    cp "${CLUSTER_PROFILE_DIR}/ssh-privatekey" ~/.ssh/google_compute_engine || true
    PROJECT="$(oc get -o jsonpath='{.status.platformStatus.gcp.projectID}' infrastructure cluster)"
    REGION="$(oc get -o jsonpath='{.status.platformStatus.gcp.region}' infrastructure cluster)"
    export TEST_PROVIDER="{\"type\":\"gce\",\"region\":\"${REGION}\",\"multizone\": true,\"multimaster\":true,\"projectid\":\"${PROJECT}\"}"
    ;;
aws)
    mkdir -p ~/.ssh
    cp "${CLUSTER_PROFILE_DIR}/ssh-privatekey" ~/.ssh/kube_aws_rsa || true
    export PROVIDER_ARGS="-provider=aws -gce-zone=us-east-1"
    REGION="$(oc get -o jsonpath='{.status.platformStatus.aws.region}' infrastructure cluster)"
    ZONE="$(oc get -o jsonpath='{.items[0].metadata.labels.failure-domain\.beta\.kubernetes\.io/zone}' nodes)"
    export TEST_PROVIDER="{\"type\":\"aws\",\"region\":\"${REGION}\",\"zone\":\"${ZONE}\",\"multizone\":true,\"multimaster\":true}"
    export KUBE_SSH_USER=core
    ;;
azure4) export TEST_PROVIDER=azure;;
azurestack)
    export TEST_PROVIDER="none"
    export AZURE_AUTH_LOCATION=${SHARED_DIR}/osServicePrincipal.json
    ;;
vsphere)
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/govc.sh"
    export VSPHERE_CONF_FILE="${SHARED_DIR}/vsphere.conf"
    oc -n openshift-config get cm/cloud-provider-config -o jsonpath='{.data.config}' > "$VSPHERE_CONF_FILE"
    # The test suite requires a vSphere config file with explicit user and password fields.
    sed -i "/secret-name \=/c user = \"${GOVC_USERNAME}\"" "$VSPHERE_CONF_FILE"
    sed -i "/secret-namespace \=/c password = \"${GOVC_PASSWORD}\"" "$VSPHERE_CONF_FILE"
    export TEST_PROVIDER=vsphere;;
openstack*)
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/cinder_credentials.sh"
    export TEST_PROVIDER='{"type":"openstack"}';;
ovirt) export TEST_PROVIDER='{"type":"ovirt"}';;
packet)
    export TEST_PROVIDER='{"type":"skeleton"}';;
*) echo >&2 "Unsupported cluster type '${CLUSTER_TYPE}'"; exit 1;;
esac

# create execution directory
mkdir -p /tmp/output
cd /tmp/output

if [[ "${CLUSTER_TYPE}" == gcp ]]; then
    pushd /tmp
    curl -O https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-sdk-256.0.0-linux-x86_64.tar.gz
    tar -xzf google-cloud-sdk-256.0.0-linux-x86_64.tar.gz
    export PATH=$PATH:/tmp/google-cloud-sdk/bin
    mkdir -p gcloudconfig
    export CLOUDSDK_CONFIG=/tmp/gcloudconfig
    gcloud auth activate-service-account --key-file="${GCP_SHARED_CREDENTIALS_FILE}"
    gcloud config set project "${PROJECT}"
    popd
fi

echo "$(date +%s)" > "${SHARED_DIR}/TEST_TIME_TEST_START"
trap 'echo "$(date +%s)" > "${SHARED_DIR}/TEST_TIME_TEST_END"' EXIT

# check if the cluster is ready
oc wait nodes --all --for=condition=Ready=true --timeout=10m
oc wait clusteroperators --all --for=condition=Progressing=false --timeout=10m

# execute the cases
function run {
    test_scenarios=""
    echo "TEST_SCENRAIOS: \"${TEST_SCENRAIOS:-}\""
    echo "TEST_IMPORTANCE: \"${TEST_IMPORTANCE}\""
    echo "TEST_FILTERS: \"~Flaky&;~CPaasrunOnly&;~VMonly&;~ProdrunOnly&;~StagerunOnly&;${TEST_FILTERS}\""
    echo "TEST_TIMEOUT: \"${TEST_TIMEOUT}\""
    if [[ -n "${TEST_SCENRAIOS:-}" ]]; then
        readarray -t scenarios <<< "${TEST_SCENRAIOS}"
        for scenario in "${scenarios[@]}"; do
            test_scenarios="${test_scenarios}|${scenario}"
        done
    else
        echo "there is no scenario"
        return
    fi

    if [ "W${test_scenarios}W" == "WW" ]; then
        echo "fail to parse ${TEST_SCENRAIOS}"
        exit 1
    fi
    echo "scenarios: ${test_scenarios:1:-1}"
    extended-platform-tests run all --dry-run | \
        grep -E "${test_scenarios:1:-1}" | grep -E "${TEST_IMPORTANCE}" > ./case_selected

    handle_filters "~Flaky&;~CPaasrunOnly&;~VMonly&;~ProdrunOnly&;~StagerunOnly&;${TEST_FILTERS}"
    echo "------------------the case selected------------------"
    cat ./case_selected|wc -l
    cat ./case_selected
    echo "-----------------------------------------------------"

    set -x
    if [ "W${TEST_PROVIDER}W" == "WnoneW" ]; then
        extended-platform-tests run --max-parallel-tests ${TEST_PARALLEL} \
        -o "${ARTIFACT_DIR}/extended.log" \
        --timeout "${TEST_TIMEOUT}m" --junit-dir="${ARTIFACT_DIR}/junit" -f ./case_selected
    else
        extended-platform-tests run --max-parallel-tests ${TEST_PARALLEL} \
        --provider "${TEST_PROVIDER}" -o "${ARTIFACT_DIR}/extended.log" \
        --timeout "${TEST_TIMEOUT}m" --junit-dir="${ARTIFACT_DIR}/junit" -f ./case_selected
    fi
    set +x
    rm -fr ./case_selected
}

# select the cases per FILTERS
function handle_filters {
    filter_tmp="$1"
    if [ "W${filter_tmp}W" == "WW" ]; then
        echo "there is no filter"
        return
    fi
    echo "try to handler filters..."
    IFS=";" read -r -a filters <<< "${filter_tmp}"

    filters_and=()
    filters_or=()
    for filter in "${filters[@]}"
    do
        echo "${filter}"
        valid_filter "${filter}"
        filter_logical="$(echo $filter | grep -Eo '[&]?$')"

        if [ "W${filter_logical}W" == "W&W" ]; then
            filters_and+=( "$filter" )
        else
            filters_or+=( "$filter" )
        fi
    done

    echo "handle AND logical"
    for filter in ${filters_and[*]}
    do
        echo "handle filter_and ${filter}"
        handle_and_filter "${filter}"
    done

    echo "handle OR logical"
    rm -fr ./case_selected_or
    for filter in ${filters_or[*]}
    do
        echo "handle filter_or ${filter}"
        handle_or_filter "${filter}"
    done
    if [[ -e ./case_selected_or ]]; then
        sort -u ./case_selected_or > ./case_selected && rm -fr ./case_selected_or
    fi
}

function valid_filter {
    filter="$1"
    if ! echo ${filter} | grep -E '^[~]?[a-zA-Z0-9]{1,}[&]?$'; then
        echo "the filter ${filter} is not correct format. it should be ^[~]?[a-zA-Z0-9]{1,}[&]?$"
        exit 1
    fi
    action="$(echo $filter | grep -Eo '^[~]?')"
    value="$(echo $filter | grep -Eo '[a-zA-Z0-9]{1,}')"
    logical="$(echo $filter | grep -Eo '[&]?$')"
    echo "$action--$value--$logical"
}

function handle_and_filter {
    action="$(echo $1 | grep -Eo '^[~]?')"
    value="$(echo $1 | grep -Eo '[a-zA-Z0-9]{1,}')"

    if [ "W${action}W" == "WW" ]; then
        cat ./case_selected | grep -E "${value}" > ./case_selected_and
    else
        cat ./case_selected | grep -v -E "${value}" > ./case_selected_and
    fi
    if [[ -e ./case_selected_and ]]; then
        cp -fr ./case_selected_and ./case_selected && rm -fr ./case_selected_and
    fi
}

function handle_or_filter {
    action="$(echo $1 | grep -Eo '^[~]?')"
    value="$(echo $1 | grep -Eo '[a-zA-Z0-9]{1,}')"

    if [ "W${action}W" == "WW" ]; then
        cat ./case_selected | grep -E "${value}" >> ./case_selected_or
    else
        cat ./case_selected | grep -v -E "${value}" >> ./case_selected_or
    fi
}
run
