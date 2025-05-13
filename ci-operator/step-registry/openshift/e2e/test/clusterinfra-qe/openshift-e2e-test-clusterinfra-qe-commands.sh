#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function save_oidc_tokens {
    echo "Saving oidc tokens back to SHARED_DIR"
    cp "$token_cache_dir"/* "$SHARED_DIR"/oc-oidc-token
    ls "$token_cache_dir" >"$SHARED_DIR"/oc-oidc-token-filename
}

function exit_trap {
    echo "Exit trap triggered"
    date '+%s' >"${SHARED_DIR}/TEST_TIME_TEST_END" || :
    if [[ -r "$SHARED_DIR/oc-oidc-token" ]] && [[ -r "$SHARED_DIR/oc-oidc-token-filename" ]]; then
        save_oidc_tokens
    fi
}

trap 'exit_trap' EXIT
trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export AWS_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/.awscred
export AZURE_AUTH_LOCATION=${CLUSTER_PROFILE_DIR}/osServicePrincipal.json
export GCP_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/gce.json
export HOME=/tmp/home
export PATH=/usr/local/go/bin:/usr/libexec/origin:/opt/OpenShift4-tools:$PATH
export ENABLE_PRINT_EVENT_STDOUT=true

# add for hosted kubeconfig in the hosted cluster env
if test -f "${SHARED_DIR}/nested_kubeconfig"; then
    export GUEST_KUBECONFIG=${SHARED_DIR}/nested_kubeconfig
fi

# although we set this env var, but it does not exist if the CLUSTER_TYPE is not gcp.
# so, currently some cases need to access gcp service whether the cluster_type is gcp or not
# and they will fail, like some cvo cases, because /var/run/secrets/ci.openshift.io/cluster-profile/gce.json does not exist.
export GOOGLE_APPLICATION_CREDENTIALS="${GCP_SHARED_CREDENTIALS_FILE}"

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

# setup proxy
if test -f "${SHARED_DIR}/proxy-conf.sh"; then
    source "${SHARED_DIR}/proxy-conf.sh"
fi

# restore external oidc cache dir for oc
if [[ -r "$SHARED_DIR/oc-oidc-token" ]] && [[ -r "$SHARED_DIR/oc-oidc-token-filename" ]]; then
    echo "Restoring external OIDC cache dir for oc"
    export KUBECACHEDIR
    KUBECACHEDIR="/tmp/output/oc-oidc"
    token_cache_dir="$KUBECACHEDIR/oc"
    mkdir -p "$token_cache_dir"
    cat "$SHARED_DIR/oc-oidc-token" >"$token_cache_dir/$(cat "$SHARED_DIR/oc-oidc-token-filename")"
    oc whoami
fi

#set env for kubeadmin
if [ -f "${SHARED_DIR}/kubeadmin-password" ]; then
    QE_KUBEADMIN_PASSWORD=$(cat "${SHARED_DIR}/kubeadmin-password")
    export QE_KUBEADMIN_PASSWORD
fi

# setup bastion
if test -f "${SHARED_DIR}/bastion_public_address"; then
    QE_BASTION_PUBLIC_ADDRESS=$(cat "${SHARED_DIR}/bastion_public_address")
    export QE_BASTION_PUBLIC_ADDRESS
fi
if test -f "${SHARED_DIR}/bastion_private_address"; then
    QE_BASTION_PRIVATE_ADDRESS=$(cat "${SHARED_DIR}/bastion_private_address")
    export QE_BASTION_PRIVATE_ADDRESS
fi
if test -f "${SHARED_DIR}/bastion_ssh_user"; then
    QE_BASTION_SSH_USER=$(cat "${SHARED_DIR}/bastion_ssh_user")
fi

if test -f "${SHARED_DIR}/bastion_public_address" || test -f "${SHARED_DIR}/bastion_private_address" || oc get service ssh-bastion -n "${SSH_BASTION_NAMESPACE:-test-ssh-bastion}" &>/dev/null; then
    echo "Ensure our UID, which is randomly generated, is in /etc/passwd. This is required to be able to SSH"
    if ! whoami &>/dev/null; then
        echo "try to add user ${USER_NAME:-default}"
        if [[ -w /etc/passwd ]]; then
            echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >>/etc/passwd
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
if test -f "${CLUSTER_PROFILE_DIR}/ocm-token"; then
    TEST_ROSA_TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/ocm-token") || true
    export TEST_ROSA_TOKEN
fi
if test -f "${SHARED_DIR}/cluster-id"; then
    CLUSTER_ID=$(cat "${SHARED_DIR}/cluster-id") || true
    export CLUSTER_ID
fi

# configure environment for different cluster
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
aws-usgov | aws-c2s | aws-sc2s)
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
azure4 | azuremag | azure-arm64)
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
    oc -n openshift-config get cm/cloud-provider-config -o jsonpath='{.data.config}' >"$VSPHERE_CONF_FILE" || error_code=$?
    if [ "W${error_code}W" == "W0W" ]; then
        # The test suite requires a vSphere config file with explicit user and password fields.
        sed -i "/secret-name \=/c user = \"${GOVC_USERNAME}\"" "$VSPHERE_CONF_FILE"
        sed -i "/secret-namespace \=/c password = \"${GOVC_PASSWORD}\"" "$VSPHERE_CONF_FILE"
    fi
    export TEST_PROVIDER=vsphere
    ;;
openstack*)
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/cinder_credentials.sh"
    export TEST_PROVIDER='{"type":"openstack"}'
    ;;
ibmcloud)
    export TEST_PROVIDER='{"type":"ibmcloud"}'
    export SSH_CLOUD_PRIV_IBMCLOUD_USER="${QE_BASTION_SSH_USER:-core}"
    IC_API_KEY="$(<"${CLUSTER_PROFILE_DIR}/ibmcloud-api-key")"
    export IC_API_KEY
    ;;
ovirt) export TEST_PROVIDER='{"type":"ovirt"}' ;;
equinix-ocp-metal | equinix-ocp-metal-qe | powervs-*)
    export TEST_PROVIDER='{"type":"skeleton"}'
    ;;
nutanix | nutanix-qe | nutanix-qe-dis)
    export TEST_PROVIDER='{"type":"nutanix"}'
    ;;
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
    curl -O https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-sdk-318.0.0-linux-x86_64.tar.gz
    tar -xzf google-cloud-sdk-318.0.0-linux-x86_64.tar.gz
    export PATH=$PATH:/tmp/google-cloud-sdk/bin
    mkdir -p gcloudconfig
    export CLOUDSDK_CONFIG=/tmp/gcloudconfig
    gcloud auth activate-service-account --key-file="${GCP_SHARED_CREDENTIALS_FILE}"
    gcloud config set project "${PROJECT}"
    popd
fi

echo "$(date +%s)" >"${SHARED_DIR}/TEST_TIME_TEST_START"

# check if the cluster is ready
oc version --client
oc wait nodes --all --for=condition=Ready=true --timeout=15m
if [[ $IS_ACTIVE_CLUSTER_OPENSHIFT != "false" ]]; then
    oc wait clusteroperators --all --for=condition=Progressing=false --timeout=15m
    oc get clusterversion version -o yaml || true
fi

# execute the cases
function run {
    cd /go/src/github.com/openshift/cluster-api-actuator-pkg
    # failures happening after this point should not be caught by the Overall CI test suite in RP
    touch "${ARTIFACT_DIR}/skip_overall_if_fail"
    ret_value=0
    set -x
    echo "TEST_FILTERS_CLUSTERINFRASTRUCTURE: \"${TEST_FILTERS_CLUSTERINFRASTRUCTURE:-}\""
    if [[ -n "$TEST_FILTERS_CLUSTERINFRASTRUCTURE" ]]; then
        hack/ci-integration.sh --junit-report=junit_cluster-api-actuator-testutils.xml --output-dir=/logs/artifacts/ --label-filter="${TEST_FILTERS_CLUSTERINFRASTRUCTURE}" -p || ret_value=$?
    else
        hack/ci-integration.sh --junit-report=junit_cluster-api-actuator-testutils.xml --output-dir=/logs/artifacts/ --label-filter='!disruptive&&!autoscaler' -p || ret_value=$?
    fi
    set +x
    set +e
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
    if ! [[ -d "${ARTIFACT_DIR:-'/default-non-exist-dir'}" ]]; then
        echo "Artifact dir '${ARTIFACT_DIR}' not exist"
        exit 0
    else
        echo "Artifact dir '${ARTIFACT_DIR}' exist"
        ls -lR "${ARTIFACT_DIR}"
        files="$(find "${ARTIFACT_DIR}" -name '*.xml' | wc -l)"
        if [[ "$files" -eq 0 ]]; then
            echo "There are no JUnit files"
            exit 0
        fi
    fi
    declare -A results=([failures]='0' [errors]='0' [skipped]='0' [tests]='0')
    input_file="/tmp/zzz-tmp.log"
    grep -r -E -h -o 'testsuite.*tests="[0-9]+"[^>]*' "${ARTIFACT_DIR}" >"$input_file" || exit 0
    while read row; do
        for ctype in "${!results[@]}"; do
            count="$(sed -E "s/.*$ctype=\"([0-9]+)\".*/\1/" <<<$row)"
            if [[ -n $count ]]; then
                let results[$ctype]+=count || true
            fi
        done
    done <"$input_file"

    TEST_RESULT_FILE="${ARTIFACT_DIR}/test-results.yaml"
    cat >"${TEST_RESULT_FILE}" <<-EOF
openshift-e2e-test-clusterinfra-qe:
  total: ${results[tests]}
  failures: ${results[failures]}
  errors: ${results[errors]}
  skipped: ${results[skipped]}
EOF
    if [ ${results[failures]} != 0 ]; then
        echo '  failingScenarios:' >>"${TEST_RESULT_FILE}"
        # Every failure scenario should have a directory in machine-api-e2e-suite, if the directory exist get failure scenarios from machine-api-e2e-suite
        if [ -d "${ARTIFACT_DIR}/machine-api-e2e-suite" ]; then
            readarray -t failingscenarios < <(find "${ARTIFACT_DIR}/machine-api-e2e-suite/" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort --unique)
            for ((i = 0; i < ${#failingscenarios[@]}; i++)); do
                echo "    - ${failingscenarios[$i]}" >>"${TEST_RESULT_FILE}"
            done
        else
            # If machine-api-e2e-suite directory doesn't exist, get failure scenarios from import-Cluster_Infrastructure.xml
            if [ -f "${ARTIFACT_DIR}/junit/import-Cluster_Infrastructure.xml" ]; then
                readarray -t failingscenarios < <(awk -F 'name="' '/status="failed"/ {split($2, arr, "\""); print arr[1]}' "${ARTIFACT_DIR}/junit/import-Cluster_Infrastructure.xml")
                for ((i = 0; i < ${#failingscenarios[@]}; i++)); do
                    echo "    - ${failingscenarios[$i]}" >>"${TEST_RESULT_FILE}"
                done
            else
                echo "Error: XML file not found at ${ARTIFACT_DIR}/junit/import-Cluster_Infrastructure.xml" >&2
            fi
        fi
    fi
    cat "${TEST_RESULT_FILE}" | tee -a "${SHARED_DIR}/openshift-e2e-test-qe-report" || true

    # it ensure the the step after this step in test will be executed per https://docs.ci.openshift.org/docs/architecture/step-registry/#workflow
    # please refer to the junit result for case result, not depends on step result.
    if [ "W${FORCE_SUCCESS_EXIT}W" == "WnoW" ]; then
        echo "do not force success exit"
        exit $ret_value
    fi
}

function handle_result {
    ls "${ARTIFACT_DIR}"
    resultfile=$(ls -rt -1 "${ARTIFACT_DIR}/junit_cluster-api-actuator-testutils.xml" 2>&1 || true)
    echo "$resultfile"
    if (echo $resultfile | grep -E "no matches found") || (echo $resultfile | grep -E "No such file or directory"); then
        echo "there is no result file generated"
        return
    fi

    split_ret=0
    cp /go/src/github.com/openshift/cluster-api-actuator-pkg/pipeline/handleresult.py /tmp/handleresult.py
    cd /tmp/output
    python3 /tmp/handleresult.py -a split -i ${resultfile} || split_ret=$?
    if ! [ "W${split_ret}W" == "W0W" ]; then
        echo "splitting file is not ok"
        rm -fr ${resultfile}
        return
    fi
    mkdir -p "${ARTIFACT_DIR}/junit/"
    cp -fr import-*.xml "${ARTIFACT_DIR}/junit/"
    rm -fr ${resultfile}
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
