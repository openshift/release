#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export AWS_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/.awscred
export AZURE_AUTH_LOCATION=${CLUSTER_PROFILE_DIR}/osServicePrincipal.json
export GCP_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/gce.json
export HOME=/tmp/home
export PATH=/usr/local/go/bin:/usr/libexec/origin:/opt/OpenShift4-tools:$PATH
export REPORT_HANDLE_PATH="/usr/bin"
export ENABLE_PRINT_EVENT_STDOUT=true

# add for hosted kubeconfig in the hosted cluster env
if test -f "${SHARED_DIR}/nested_kubeconfig"
then
    export GUEST_KUBECONFIG=${SHARED_DIR}/nested_kubeconfig
fi

# although we set this env var, but it does not exist if the CLUSTER_TYPE is not gcp.
# so, currently some cases need to access gcp service whether the cluster_type is gcp or not
# and they will fail, like some cvo cases, because /var/run/secrets/ci.openshift.io/cluster-profile/gce.json does not exist.
export GOOGLE_APPLICATION_CREDENTIALS="${GCP_SHARED_CREDENTIALS_FILE}"

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

# prepare for the future usage on the kubeconfig generation of different workflow
test -n "${KUBECONFIG:-}" && echo "${KUBECONFIG}" || echo "no KUBECONFIG is defined"
test -f "${KUBECONFIG}" && (ls -l "${KUBECONFIG}" || true) || echo "kubeconfig file does not exist"
ls -l ${SHARED_DIR}/kubeconfig || echo "no kubeconfig in shared_dir"
ls -l ${SHARED_DIR}/kubeadmin-password && echo "kubeadmin passwd exists" || echo "no kubeadmin passwd in shared_dir"

# create link for oc to kubectl
mkdir -p "${HOME}"
if ! which kubectl; then
    export PATH=$PATH:$HOME
    ln -s "$(which oc)" ${HOME}/kubectl
fi

which extended-platform-tests

# setup proxy
if test -f "${SHARED_DIR}/proxy-conf.sh"
then
    source "${SHARED_DIR}/proxy-conf.sh"
fi

#setup bastion
if test -f "${SHARED_DIR}/bastion_public_address"
then
    QE_BASTION_PUBLIC_ADDRESS=$(cat "${SHARED_DIR}/bastion_public_address")
    export QE_BASTION_PUBLIC_ADDRESS
fi
if test -f "${SHARED_DIR}/bastion_private_address"
then
    QE_BASTION_PRIVATE_ADDRESS=$(cat "${SHARED_DIR}/bastion_private_address")
    export QE_BASTION_PRIVATE_ADDRESS
fi
if test -f "${SHARED_DIR}/bastion_ssh_user"
then
    QE_BASTION_SSH_USER=$(cat "${SHARED_DIR}/bastion_ssh_user")
fi

if test -f "${SHARED_DIR}/bastion_public_address" ||  test -f "${SHARED_DIR}/bastion_private_address" || oc get service ssh-bastion -n "${SSH_BASTION_NAMESPACE:-test-ssh-bastion}" &> /dev/null
then
    echo "Ensure our UID, which is randomly generated, is in /etc/passwd. This is required to be able to SSH"
    if ! whoami &> /dev/null; then
        echo "try to add user ${USER_NAME:-default}"
        if [[ -w /etc/passwd ]]; then
            echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >> /etc/passwd
            echo "added user ${USER_NAME:-default}"
        fi
    fi
else
    echo "do not need to ensure UID in passwd"
fi

mkdir -p ~/.ssh
cp "${CLUSTER_PROFILE_DIR}/ssh-privatekey" ~/.ssh/ssh-privatekey || true
chmod 0600 ~/.ssh/ssh-privatekey || true
eval export SSH_CLOUD_PRIV_KEY="~/.ssh/ssh-privatekey"

test -f "${CLUSTER_PROFILE_DIR}/ssh-publickey" || echo "ssh-publickey file does not exist"
cp "${CLUSTER_PROFILE_DIR}/ssh-publickey" ~/.ssh/ssh-publickey || true
chmod 0644 ~/.ssh/ssh-publickey || true
eval export SSH_CLOUD_PUB_KEY="~/.ssh/ssh-publickey"

#set env for rosa which are required by hypershift qe team
if test -f "${CLUSTER_PROFILE_DIR}/ocm-token"
then
    TEST_ROSA_TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/ocm-token") || true
    export TEST_ROSA_TOKEN
fi

# configure enviroment for different cluster
echo "CLUSTER_TYPE is ${CLUSTER_TYPE}"
case "${CLUSTER_TYPE}" in
gcp)
    export GOOGLE_APPLICATION_CREDENTIALS="${GCP_SHARED_CREDENTIALS_FILE}"
    export KUBE_SSH_USER=core
    export SSH_CLOUD_PRIV_GCP_USER="${QE_BASTION_SSH_USER:-core}"
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
    export SSH_CLOUD_PRIV_AWS_USER="${QE_BASTION_SSH_USER:-core}"
    ;;
aws-usgov|aws-c2s|aws-sc2s)
    mkdir -p ~/.ssh
    export SSH_CLOUD_PRIV_AWS_USER="${QE_BASTION_SSH_USER:-core}"
    export KUBE_SSH_USER=core
    export TEST_PROVIDER="none"
    ;;
alibabacloud)
    mkdir -p ~/.ssh
    cp "${CLUSTER_PROFILE_DIR}/ssh-privatekey" ~/.ssh/kube_alibaba_rsa || true
    export SSH_CLOUD_PRIV_ALIBABA_USER="${QE_BASTION_SSH_USER:-core}"
    export KUBE_SSH_USER=core
    export PROVIDER_ARGS="-provider=alibabacloud -gce-zone=us-east-1"
    REGION="$(oc get -o jsonpath='{.status.platformStatus.alibabacloud.region}' infrastructure cluster)"
    export TEST_PROVIDER="{\"type\":\"alibabacloud\",\"region\":\"${REGION}\",\"multizone\":true,\"multimaster\":true}"
;;
azure4|azuremag|azure-arm64)
    mkdir -p ~/.ssh
    cp "${CLUSTER_PROFILE_DIR}/ssh-privatekey" ~/.ssh/kube_azure_rsa || true
    export SSH_CLOUD_PRIV_AZURE_USER="${QE_BASTION_SSH_USER:-core}"
    export TEST_PROVIDER=azure
    ;;
azurestack)
    export TEST_PROVIDER="none"
    export AZURE_AUTH_LOCATION=${SHARED_DIR}/osServicePrincipal.json
    ;;
vsphere)
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/govc.sh"
    export VSPHERE_CONF_FILE="${SHARED_DIR}/vsphere.conf"
    error_code=0
    oc -n openshift-config get cm/cloud-provider-config -o jsonpath='{.data.config}' > "$VSPHERE_CONF_FILE" || error_code=$?
    if [ "W${error_code}W" == "W0W" ]; then
        # The test suite requires a vSphere config file with explicit user and password fields.
        sed -i "/secret-name \=/c user = \"${GOVC_USERNAME}\"" "$VSPHERE_CONF_FILE"
        sed -i "/secret-namespace \=/c password = \"${GOVC_PASSWORD}\"" "$VSPHERE_CONF_FILE"
    fi
    export TEST_PROVIDER=vsphere;;
openstack*)
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/cinder_credentials.sh"
    export TEST_PROVIDER='{"type":"openstack"}';;
ibmcloud)
    export TEST_PROVIDER='{"type":"ibmcloud"}'
    IC_API_KEY="$(< "${CLUSTER_PROFILE_DIR}/ibmcloud-api-key")"
    export IC_API_KEY;;
ovirt) export TEST_PROVIDER='{"type":"ovirt"}';;
equinix-ocp-metal|equinix-ocp-metal-qe|powervs-1)
    export TEST_PROVIDER='{"type":"skeleton"}';;
nutanix|nutanix-qe|nutanix-qe-dis)
    export TEST_PROVIDER='{"type":"nutanix"}';;
*)
    echo >&2 "Unsupported cluster type '${CLUSTER_TYPE}'"
    if [ "W${FORCE_SUCCESS_EXIT}W" == "WnoW" ]; then
        echo "do not force success exit"
        exit 1
    fi
    echo "force success exit"
    exit 0
    ;;
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
oc version --client
oc wait nodes --all --for=condition=Ready=true --timeout=15m
oc wait clusteroperators --all --for=condition=Progressing=false --timeout=15m
oc get clusterversion version -o yaml || true

# execute the cases
function run {
    test_scenarios=""
    echo "TEST_SCENARIOS_SUPPLEMENTARY: \"${TEST_SCENARIOS_SUPPLEMENTARY:-}\""
    echo "TEST_ADDITIONAL_SUPPLEMENTARY: \"${TEST_ADDITIONAL_SUPPLEMENTARY:-}\""
    echo "TEST_IMPORTANCE: \"${TEST_IMPORTANCE}\""
    echo "TEST_TIMEOUT_SUPPLEMENTARY: \"${TEST_TIMEOUT_SUPPLEMENTARY}\""
    if [[ -n "${TEST_SCENARIOS_SUPPLEMENTARY:-}" ]]; then
        readarray -t scenarios <<< "${TEST_SCENARIOS_SUPPLEMENTARY}"
        for scenario in "${scenarios[@]}"; do
            if [ "W${scenario}W" != "WW" ]; then
                test_scenarios="${test_scenarios}|${scenario}"
            fi
        done
    else
        echo "there is no scenario"
        return
    fi

    if [ "W${test_scenarios}W" == "WW" ]; then
        echo "fail to parse ${TEST_SCENARIOS_SUPPLEMENTARY}"
        exit 1
    fi
    echo "test scenarios: ${test_scenarios:1}"
    test_scenarios="${test_scenarios:1}"

    test_additional=""
    if [[ -n "${TEST_ADDITIONAL_SUPPLEMENTARY:-}" ]]; then
        readarray -t additionals <<< "${TEST_ADDITIONAL_SUPPLEMENTARY}"
        for additional in "${additionals[@]}"; do
            test_additional="${test_additional}|${additional}"
        done
    else
        echo "there is no additional"
    fi

    if [ "W${test_additional}W" != "WW" ]; then
        if [ "W${test_additional: -1}W" != "W|W" ]; then
            echo "test additional: ${test_additional:1}"
            test_scenarios="${test_scenarios}|${test_additional:1}"
        else
            echo "test additional: ${test_additional:1:-1}"
            test_scenarios="${test_scenarios}|${test_additional:1:-1}"
        fi
    fi

    echo "final scenarios: ${test_scenarios}"
    extended-platform-tests run all --dry-run | \
        grep -E "${test_scenarios}" | grep -E "${TEST_IMPORTANCE}" > ./case_selected

    hardcoded_filters="~NonUnifyCI&;~DEPRECATED&;~CPaasrunOnly&;~VMonly&;~ProdrunOnly&;~StagerunOnly&"
    if [[ "${test_scenarios}" == *"Stagerun"* ]] && [[ "${test_scenarios}" != *"~Stagerun"* ]]; then
        hardcoded_filters="~NonUnifyCI&;~Flaky&;~DEPRECATED&;~CPaasrunOnly&;~VMonly&;~ProdrunOnly&"
    fi
    echo "TEST_FILTERS_SUPPLEMENTARY: \"${hardcoded_filters};${TEST_FILTERS_SUPPLEMENTARY:-}\""
    echo "FILTERS_ADDITIONAL_SUPPLEMENTARY: \"${FILTERS_ADDITIONAL_SUPPLEMENTARY:-}\""
    test_filters="${hardcoded_filters};${TEST_FILTERS_SUPPLEMENTARY}"
    if [[ -n "${FILTERS_ADDITIONAL_SUPPLEMENTARY:-}" ]]; then
        echo "add FILTERS_ADDITIONAL_SUPPLEMENTARY into test_filters"
        test_filters="${hardcoded_filters};${TEST_FILTERS_SUPPLEMENTARY};${FILTERS_ADDITIONAL_SUPPLEMENTARY}"
    fi
    echo "${test_filters}"
    handle_filters "${test_filters}"
    echo "------------------the case selected------------------"
    selected_case_num=$(cat ./case_selected|wc -l)
    if [ "W${selected_case_num}W" == "W0W" ]; then
        echo "No Case Selected"
        if [ "W${FORCE_SUCCESS_EXIT}W" == "WnoW" ]; then
            echo "do not force success exit"
            exit 1
        fi
        echo "force success exit"
        exit 0
    fi
    echo ${selected_case_num}
    cat ./case_selected
    echo "-----------------------------------------------------"

    # failures happening after this point should not be caught by the Overall CI test suite in RP
    touch "${ARTIFACT_DIR}/skip_overall_if_fail"
    ret_value=0
    set -x
    if [ "W${TEST_PROVIDER}W" == "WnoneW" ]; then
        extended-platform-tests run --max-parallel-tests ${TEST_PARALLEL} \
        -o "${ARTIFACT_DIR}/extended.log" \
        --timeout "${TEST_TIMEOUT_SUPPLEMENTARY}m" --junit-dir="${ARTIFACT_DIR}/junit" -f ./case_selected || ret_value=$?
    else
        extended-platform-tests run --max-parallel-tests ${TEST_PARALLEL} \
        --provider "${TEST_PROVIDER}" -o "${ARTIFACT_DIR}/extended.log" \
        --timeout "${TEST_TIMEOUT_SUPPLEMENTARY}m" --junit-dir="${ARTIFACT_DIR}/junit" -f ./case_selected || ret_value=$?
    fi
    set +x
    set +e
    rm -fr ./case_selected
    echo "try to handle result"
    handle_result
    echo "done to handle result"
    if [ "W${ret_value}W" == "W0W" ]; then
        echo "success"
    else
        echo "fail"
    fi

    # summarize test results
    echo "Summarizing test results..."
    failures=0 errors=0 skipped=0 tests=0
    grep -r -E -h -o 'testsuite.*tests="[0-9]+"' "${ARTIFACT_DIR}" | tr -d '[A-Za-z=\"_]' > /tmp/zzz-tmp.log
    while read -a row ; do
        # if the last ARG of command `let` evaluates to 0, `let` returns 1
        let errors+=${row[0]} failures+=${row[1]} skipped+=${row[2]} tests+=${row[3]} || true
    done < /tmp/zzz-tmp.log

    TEST_RESULT_FILE="${ARTIFACT_DIR}/test-results.yaml"
    cat > "${TEST_RESULT_FILE}" <<- EOF
ginkgo:
  type: openshift-extended-test-supplementary
  total: $tests
  failures: $failures
  errors: $errors
  skipped: $skipped
EOF

    if [ $((failures)) != 0 ] ; then
        echo '  failingScenarios:' >> "${TEST_RESULT_FILE}"
        readarray -t failingscenarios < <(grep -h -r -E '^failed:' "${ARTIFACT_DIR}/.." | awk -v n=4 '{ for (i=n; i<=NF; i++) printf "%s%s", $i, (i<NF ? OFS : ORS)}' | sort --unique)
        for (( i=0; i<${#failingscenarios[@]}; i++ )) ; do
            echo "    - ${failingscenarios[$i]}" >> "${TEST_RESULT_FILE}"
        done
    fi
    cat "${TEST_RESULT_FILE}" | tee -a "${SHARED_DIR}/openshift-e2e-test-qe-report" || true

    # it ensure the the step after this step in test will be executed per https://docs.ci.openshift.org/docs/architecture/step-registry/#workflow
    # please refer to the junit result for case result, not depends on step result.
    if [ "W${FORCE_SUCCESS_EXIT}W" == "WnoW" ]; then
        echo "do not force success exit"
        exit $ret_value
    fi
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
    if ! echo ${filter} | grep -E '^[~]?[a-zA-Z0-9_]{1,}[&]?$'; then
        echo "the filter ${filter} is not correct format. it should be ^[~]?[a-zA-Z0-9_]{1,}[&]?$"
        exit 1
    fi
    action="$(echo $filter | grep -Eo '^[~]?')"
    value="$(echo $filter | grep -Eo '[a-zA-Z0-9_]{1,}')"
    logical="$(echo $filter | grep -Eo '[&]?$')"
    echo "$action--$value--$logical"
}

function handle_and_filter {
    action="$(echo $1 | grep -Eo '^[~]?')"
    value="$(echo $1 | grep -Eo '[a-zA-Z0-9_]{1,}')"

    ret=0
    if [ "W${action}W" == "WW" ]; then
        cat ./case_selected | grep -E "${value}" > ./case_selected_and || ret=$?
        check_case_selected "${ret}"
    else
        cat ./case_selected | grep -v -E "${value}" > ./case_selected_and || ret=$?
        check_case_selected "${ret}"
    fi
    if [[ -e ./case_selected_and ]]; then
        cp -fr ./case_selected_and ./case_selected && rm -fr ./case_selected_and
    fi
}

function handle_or_filter {
    action="$(echo $1 | grep -Eo '^[~]?')"
    value="$(echo $1 | grep -Eo '[a-zA-Z0-9_]{1,}')"

    ret=0
    if [ "W${action}W" == "WW" ]; then
        cat ./case_selected | grep -E "${value}" >> ./case_selected_or || ret=$?
        check_case_selected "${ret}"
    else
        cat ./case_selected | grep -v -E "${value}" >> ./case_selected_or || ret=$?
        check_case_selected "${ret}"
    fi
}
function handle_result {
    resultfile=`ls -rt -1 ${ARTIFACT_DIR}/junit/junit_e2e_* 2>&1 || true`
    echo $resultfile
    if (echo $resultfile | grep -E "no matches found") || (echo $resultfile | grep -E "No such file or directory") ; then
        echo "there is no result file generated"
        return
    fi
    current_time=`date "+%Y-%m-%d-%H-%M-%S"`
    newresultfile="${ARTIFACT_DIR}/junit/junit_e2e_${current_time}.xml"
    replace_ret=0
    python3 ${REPORT_HANDLE_PATH}/handleresult.py -a replace -i ${resultfile} -o ${newresultfile} || replace_ret=$?
    if ! [ "W${replace_ret}W" == "W0W" ]; then
        echo "replacing file is not ok"
        rm -fr ${resultfile}
        return
    fi 
    rm -fr ${resultfile}

    echo ${newresultfile}
    split_ret=0
    python3 ${REPORT_HANDLE_PATH}/handleresult.py -a split -i ${newresultfile} || split_ret=$?
    if ! [ "W${split_ret}W" == "W0W" ]; then
        echo "splitting file is not ok"
        rm -fr ${newresultfile}
        return
    fi
    cp -fr import-*.xml "${ARTIFACT_DIR}/junit/"
    rm -fr ${newresultfile}
}
function check_case_selected {
    found_ok=$1
    if [ "W${found_ok}W" == "W0W" ]; then
        echo "find case"
    else
        echo "do not find case"
    fi
}
run
