#!/bin/bash

# set -o nounset
# set -o errexit
# set -o pipefail

# PROXY_CREDS_PATH=/var/run/vault/vsphere/proxycreds
# ADDITIONAL_CA_PATH=/var/run/vault/vsphere/additional_ca

# proxy_user=$(grep -oP 'user\s*:\s*\K.*' ${PROXY_CREDS_PATH})
# proxy_password=$(grep -oP 'password\s*:\s*\K.*' ${PROXY_CREDS_PATH})
# additional_ca=$(cat ${ADDITIONAL_CA_PATH})
# unzip -P "$(cat /var/run/bundle-secret/secret.txt)"  /tmp/bundle.zip -d  /tmp

# GRAFANACLOUND_USERNAME=$(cat /var/run/loki-grafanacloud-secret/client-id)
# ls /var/run/rp-ocp-token/*
# echo "WW$(cat /var/run/rp-ocp-token/ginkgo_rp_mmtoken)WW"
# cat /var/run/rp-ocp-token/ginkgo_rp_operatortoken
# cat /var/run/rp-ocp-token/ginkgo_rp_pmtoken
# cat /var/run/rp-ocp-token/secretsync-vault-source-path

export AWS_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/.awscred
export AZURE_AUTH_LOCATION=${CLUSTER_PROFILE_DIR}/osServicePrincipal.json
export GCP_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/gce.json
export HOME=/tmp/home
export PATH=/usr/libexec/origin:$PATH

# echo "ARTIFACT_DIR: ${ARTIFACT_DIR}"
# echo "KUBECONFIG: ${KUBECONFIG}"
echo "OPENSHIFT_CI: ${OPENSHIFT_CI}"
# echo "SHARED_DIR: ${SHARED_DIR}"
# echo "CLUSTER_PROFILE_DIR: ${CLUSTER_PROFILE_DIR}"
# echo "RELEASE_IMAGE_INITIAL: ${RELEASE_IMAGE_INITIAL}"
echo "RELEASE_IMAGE_LATEST: ${RELEASE_IMAGE_LATEST}"
# echo "KUBEADMIN_PASSWORD_FILE: ${KUBEADMIN_PASSWORD_FILE}"
# echo "IMAGE_FORMAT: ${IMAGE_FORMAT}"
echo "JOB_NAME: ${JOB_NAME}"
echo "JOB_TYPE: ${JOB_TYPE}"
echo "BUILD_ID: ${BUILD_ID}"
echo "PROW_JOB_ID: ${PROW_JOB_ID}"
echo "------------------------------"
sleep 3600
curl -s -k -v https://dave.corp.redhat.com
curl -s -k -v http://reportportal-openshift-preproc.apps.ocp-c1.prod.psi.redhat.com
curl -s -k -v https://reportportal-openshift.apps.ocp-c1.prod.psi.redhat.com


# if test -f "${SHARED_DIR}/proxy-conf.sh"
# then
#     source "${SHARED_DIR}/proxy-conf.sh"
# fi

# trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

# mkdir -p "${HOME}"

# case "${CLUSTER_TYPE}" in
# gcp)
#     export GOOGLE_APPLICATION_CREDENTIALS="${GCP_SHARED_CREDENTIALS_FILE}"
#     export KUBE_SSH_USER=core
#     mkdir -p ~/.ssh
#     cp "${CLUSTER_PROFILE_DIR}/ssh-privatekey" ~/.ssh/google_compute_engine || true
#     PROJECT="$(oc get -o jsonpath='{.status.platformStatus.gcp.projectID}' infrastructure cluster)"
#     REGION="$(oc get -o jsonpath='{.status.platformStatus.gcp.region}' infrastructure cluster)"
#     export TEST_PROVIDER="{\"type\":\"gce\",\"region\":\"${REGION}\",\"multizone\": true,\"multimaster\":true,\"projectid\":\"${PROJECT}\"}"
#     ;;
# aws)
#     mkdir -p ~/.ssh
#     cp "${CLUSTER_PROFILE_DIR}/ssh-privatekey" ~/.ssh/kube_aws_rsa || true
#     export PROVIDER_ARGS="-provider=aws -gce-zone=us-east-1"
#     REGION="$(oc get -o jsonpath='{.status.platformStatus.aws.region}' infrastructure cluster)"
#     ZONE="$(oc get -o jsonpath='{.items[0].metadata.labels.failure-domain\.beta\.kubernetes\.io/zone}' nodes)"
#     export TEST_PROVIDER="{\"type\":\"aws\",\"region\":\"${REGION}\",\"zone\":\"${ZONE}\",\"multizone\":true,\"multimaster\":true}"
#     export KUBE_SSH_USER=core
#     ;;
# azure4) export TEST_PROVIDER=azure;;
# azurestack)
#     export TEST_PROVIDER="none"
#     export AZURE_AUTH_LOCATION=${SHARED_DIR}/osServicePrincipal.json
#     ;;
# *) echo >&2 "Unsupported cluster type '${CLUSTER_TYPE}'"; exit 1;;
# esac

# mkdir -p /tmp/output
# cd /tmp/output

# if [[ "${CLUSTER_TYPE}" == gcp ]]; then
#     pushd /tmp
#     curl -O https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-sdk-256.0.0-linux-x86_64.tar.gz
#     tar -xzf google-cloud-sdk-256.0.0-linux-x86_64.tar.gz
#     export PATH=$PATH:/tmp/google-cloud-sdk/bin
#     mkdir -p gcloudconfig
#     export CLOUDSDK_CONFIG=/tmp/gcloudconfig
#     gcloud auth activate-service-account --key-file="${GCP_SHARED_CREDENTIALS_FILE}"
#     gcloud config set project "${PROJECT}"
#     popd
# fi

# echo "$(date +%s)" > "${SHARED_DIR}/TEST_TIME_TEST_START"
# trap 'echo "$(date +%s)" > "${SHARED_DIR}/TEST_TIME_TEST_END"' EXIT

# echo "$(date) - waiting for nodes to be ready..."
# oc wait nodes --all --for=condition=Ready=true --timeout=10m
# echo "$(date) - all nodes are ready"

# echo "$(date) - waiting for clusteroperators to finish progressing..."
# oc wait clusteroperators --all --for=condition=Progressing=false --timeout=10m
# echo "$(date) - all clusteroperators are done progressing."


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
    extended-platform-tests run --max-parallel-tests 4 \
        --provider "${TEST_PROVIDER}" -o "${ARTIFACT_DIR}/extended.log" \
        --timeout "${TEST_TIMEOUT}m" --junit-dir="${ARTIFACT_DIR}" -f ./case_selected
    set +x
    rm -fr ./case_selected
    send_result
}

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

function send_result {
    resultfile=`ls -rt -1 ${ARTIFACT_DIR}/junit_e2e_* 2>&1 || true`
    echo $resultfile
    if (echo $resultfile | grep -E "no matches found") || (echo $resultfile | grep -E "No such file or directory") ; then
        echo "there is no result file generated"
        exit 0
    fi
    current_time=`date "+%Y-%m-%d-%H-%M-%S"`
    newresultfile="junit_e2e_${current_time}.xml"
    python3 /usr/bin/handleresult.py -a replace -i ${resultfile} -o ${newresultfile}
    echo ${newresultfile}

    if [ "W${TEST_PROFILE}W" == "WW" ]; then
        TEST_PROFILE=${CLUSTER_TYPE}
    fi

    # LAUNCHID="$(date +"%Y%m%d-%H%M_%S")CI"
    echo "get token"
    mm_token=$(cat /var/run/rp-ocp-token/ginkgo_rp_mmtoken)
    pm_token=$(cat /var/run/rp-ocp-token/ginkgo_rp_pmtoken)
    LAUNCHID="CI20200825-2258"
    rm -fr "*.zip" "import-*.xml"
    python3 /usr/bin/handleresult.py -a split -i ${newresultfile}
    for subteamfile in import-*.xml; do
        [[ -e "$subteamfile" ]] || continue
        subteam=${subteamfile:7:-4}
        eval zip -r "${LAUNCHID}.zip" "${subteamfile}"
        echo "log data ${subteamfile}"
        ret=`python3 /usr/bin/unifycirp.py -a import -f "${LAUNCHID}.zip" -s "${subteam}" -v "${TEST_VERSION}" -pn "${TEST_PROFILE}"  -t "${mm_token}" -ta "${pm_token}"  2>&1 || true`
        echo "done log data"
        eval rm -fr  "${LAUNCHID}.zip"
        result=`echo -e ${ret} | tail -1|xargs`
        if ! [ "X${result}X" == "XSUCCESSX" ]; then
            echo -e "the subteam ${subteam} result import fails\n"
            echo -e ${ret}
        fi
    done
    eval rm -fr "import-*.xml"

}
# run
