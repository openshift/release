#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

export HOME="${HOME:-/tmp/home}"
#export XDG_RUNTIME_DIR="${HOME}/run"
#export REGISTRY_AUTH_PREFERENCE=podman # TODO: remove later, used for migrating oc from docker to podman
#mkdir -p "${XDG_RUNTIME_DIR}"

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

function run_command() {
    local CMD="$1"
    echo "Running Command: ${CMD}"
    eval "${CMD}"
}

function show_time_used() {
    time_start="$1"
    time_used="$(( ($(date +%s) - time_start)/60 ))"
    echo "Tests took ${time_used} minutes"
}

set_proxy
pass=true
# get a master node
master_node_0=$(oc get node -l node-role.kubernetes.io/master= --no-headers | grep -Ev "NotReady|SchedulingDisabled"| awk '{print $1}' | awk 'NR==1{print}')
if [[ -z $master_node_0 ]]; then
    echo "Error master node0 name is null!"
    pass=false
fi
# create a ns
project="optional-scan-$RANDOM"
run_command "oc new-project $project --skip-config-write"
if [ $? == 0 ]; then
    echo "create $project project successfully"
else
    echo "fail to create $project project."
    pass=false
fi
# skip test for disconnected clusters
oc label namespace "$project" security.openshift.io/scc.podSecurityLabelSync=false pod-security.kubernetes.io/enforce=privileged pod-security.kubernetes.io/audit=privileged pod-security.kubernetes.io/warn=privileged --overwrite=true || true
cluster_http_proxy=$(oc get proxy cluster -o=jsonpath='{.spec.httpProxy}')
attempt=0
while true; do
    out=$(oc --request-timeout=60s -n "$project" debug node/"$master_node_0" -- chroot /host bash -c "export http_proxy=$cluster_http_proxy; curl -sSI ifconfig.me --connect-timeout 5" 2> /dev/null || true)
    if [[ $out == *"Via: 1.1"* ]]; then
        echo "This is not a disconnected cluster"
        break
    fi
    attempt=$(( attempt + 1 ))
    if [[ $attempt -gt 3 ]]; then
        echo "This is a disconnected cluster, skip testing"
        oc delete ns "$project"
        exit 0
    fi
    sleep 5
done

# Ensure our UID, which is randomly generated, is in /etc/passwd. This is required
# to be able to SSH.
if ! whoami &> /dev/null; then
    if [[ -w /etc/passwd ]]; then
        echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >> /etc/passwd
    else
        echo "/etc/passwd is not writeable, and user matching this uid is not found."
    fi
fi

timestamp_start="$(date +%s)"
SSH_PRIV_KEY_PATH=${CLUSTER_PROFILE_DIR}/ssh-privatekey
BASTION_IP=$(<"${SHARED_DIR}/bastion_public_address")
BASTION_SSH_USER=$(<"${SHARED_DIR}/bastion_ssh_user")
data_dir="/tmp/fips-check-optional-operators"
if [ -d "${data_dir}" ]; then
    echo "delete $data_dir"
    rm -rf ${data_dir} || true
fi
mkdir $data_dir || true
scan_result_full_log="$data_dir/scan_result.log"
scan_result_failure_csvs="$data_dir/scan_result_failure_csvs"
scan_result_succeed_with_warnings_csvs="$data_dir/scan_result_succeed_with_warnings_csvs"
scan_result_succeed_csvs="$data_dir/scan_result_succeed_csvs"
scan_result_summary="$data_dir/scan_result_summary"

oc -n openshift-config extract secret/pull-secret --to="/tmp" --confirm || true
set 644 /tmp/.dockerconfigjson || true
scp -o UserKnownHostsFile=/dev/null -o IdentityFile="${SSH_PRIV_KEY_PATH}" -o StrictHostKeyChecking=no -o LogLevel=ERROR /tmp/.dockerconfigjson ${BASTION_SSH_USER}@${BASTION_IP}:/tmp/config.json
ssh -o UserKnownHostsFile=/dev/null -o IdentityFile="${SSH_PRIV_KEY_PATH}" -o StrictHostKeyChecking=no -o LogLevel=ERROR ${BASTION_SSH_USER}@${BASTION_IP} \
    "sudo mkdir -p /tmp/tmp/.docker || true;
    sudo mv /tmp/config.json /tmp/tmp/.docker/config.json || true;
    sudo chown root:root /tmp/tmp/.docker/config.json || true;
    sudo chmod 600 /tmp/tmp/.docker/config.json || true;
    sudo ls -ltr /tmp/tmp/.docker/ || true"

#Get the package manifests from catalog source
internal=true
catalog="$DT_CATALOG_SOURCE"
echo "Using catalog '$catalog'"
oc get packagemanifests.packages.operators.coreos.com -l catalog=$catalog -o json > /tmp/$catalog.json || true

#Below is a full test
package_list=$(cat /tmp/$catalog.json | jq -r '.items[].metadata.name' | grep -iE "tempo-product|opentelemetry-product" || true)
echo -e "The full package_list in catalog '$catalog' is:\n${package_list}" || true
for package in ${package_list}; do
    echo "#Starting scan for package '$package'"
    # only select csvs with annotation `"features.operators.openshift.io/fips-compliant": "true"` to perform scan
    currentCSVs=$(cat /tmp/$catalog.json | jq -r '.items[] | select(.metadata.name=="'${package}'") | .status.channels[] | select(.currentCSVDesc.annotations["features.operators.openshift.io/fips-compliant"]=="true") | .currentCSV'| sort | uniq || true);
    if [ -z "$currentCSVs" ]; then
        echo "No CSV claimed to be fips-compliant in package '$package', skipping scan for it..."
        continue
    fi
    mkdir "${data_dir}/${package}" || true
    for csv in ${currentCSVs}; do
        csv_test_result="${data_dir}/${package}/$csv"
        echo "##Starting scan for CSV '$csv'" >> $csv_test_result
        # retrieve related images from current CSV
        image_list=$(cat /tmp/$catalog.json | jq -r '.items[].status.channels[]|select(.currentCSV=="'$csv'")|.currentCSVDesc.relatedImages[]' || true);
        if $internal; then
            image_list=$(echo $image_list | sed -r 's/registry.redhat.io/brew.registry.redhat.io/g' )
            image_list=$(echo $image_list | sed -r 's/registry.stage.redhat.io/brew.registry.stage.redhat.io/g')
        fi
        # perform fips scan by using check-payload tool
        for image_url in ${image_list}; do
            echo "###test result for image '$image_url' is:" >> $csv_test_result
            ssh -o UserKnownHostsFile=/dev/null -o IdentityFile="${SSH_PRIV_KEY_PATH}" -o StrictHostKeyChecking=no -o LogLevel=ERROR ${BASTION_SSH_USER}@${BASTION_IP} \
                "sudo podman run --rm --privileged -v /tmp/tmp/:/root/:ro registry.ci.openshift.org/ci/check-payload scan operator --spec $image_url" >> ${csv_test_result} 2>&1 || true

        done
        echo "$(cat ${csv_test_result})" >> ${scan_result_full_log}
        # summarize scan results from csv_test_result file
        resFail=$(grep -E "Failure Report" ${csv_test_result} || true)
        resSuessWithWarnings=$(grep -E "Successful run with warnings" ${csv_test_result} || true)
        if [[ -n $resFail ]];then
            echo "##Fips check for CSV '$csv' in package '$package' failed!"
            echo "$csv" >> ${scan_result_failure_csvs}
            pass=false
        elif [[ -n $resSuessWithWarnings ]];then
            echo "##Fips check for CSV '$csv' in package '$package' succeed with warnings!"
            echo "$csv" >> ${scan_result_succeed_with_warnings_csvs}
            pass=false
        else
            echo "##Fips check for CSV '$csv' in package '$package' succeed!"
            echo "$csv" >> ${scan_result_succeed_csvs}
        fi
    done
done

# check how much time used
time_used="$(( ($(date +%s) - $timestamp_start)/60 ))"
echo "Tests took ${time_used} minutes"

# generate scan result summary
echo "#fips-check result summary:" > ${scan_result_summary}
echo -e "##CSVs that failed scan:\n$(cat "${scan_result_failure_csvs}" || true)\n" >> ${scan_result_summary}
echo -e "##CSVs that succeeded scan (with warnings):\n$(cat "${scan_result_succeed_with_warnings_csvs}" || true)\n" >> ${scan_result_summary}
echo -e "##CSVs that succeeded scan (no warnings):\n$(cat "${scan_result_succeed_csvs}" || true)\n" >> ${scan_result_summary}

# generate junit report
echo "Generating the Junit for Distributed Tracing operators FIPS scan"
filename="junit_distributed_tracing_fips_scan"
testsuite="distributed-tracing-fips-scan"
subteam="Distributed_Tracing"
if $pass; then
    cat >"${ARTIFACT_DIR}/${filename}.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="${testsuite}" failures="0" errors="0" skipped="0" tests="1" time="$SECONDS">
    <testcase name="${subteam}:Distributed Tracing operators FIPS check should succeed or skip"/>
</testsuite>
EOF
else
    cat >"${ARTIFACT_DIR}/${filename}.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="${testsuite}" failures="1" errors="0" skipped="0" tests="1" time="$SECONDS">
    <testcase name="${subteam}:Optional operators scan of fips check should succeed or skip">
        <failure message="">Distributed Tracing operators claim to be FIPS-compliant but failed the fips-scan</failure>
        <system-out>$(cat "$scan_result_summary" || true)</system-out>
    </testcase>
</testsuite>
EOF
fi

# save result artifacts and cleanup
tar -czC "${data_dir}" -f "${ARTIFACT_DIR}/fips-check-optional-operators-images-scan.tar.gz" . || true
rm -rf "${data_dir}" || true
