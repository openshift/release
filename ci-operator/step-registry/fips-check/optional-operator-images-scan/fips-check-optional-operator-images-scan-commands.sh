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
data_dir="/tmp/fips-check-optional-operators/"
if [ -d "${data_dir}" ]; then
    echo "delete $data_dir"
    rm -rf ${data_dir} || true
fi
mkdir $data_dir || true
scan_result_file="$data_dir/scan_result.log"
scan_result_failure_csvs="$data_dir/scan_result_failure_csvs"
scan_result_succeed_with_warnings_csvs="$data_dir/scan_result_succeed_with_warnings_csvs"

oc -n openshift-config extract secret/pull-secret --to="/tmp" --confirm || true
set 644 /tmp/.dockerconfigjson || true
scp -o UserKnownHostsFile=/dev/null -o IdentityFile="${SSH_PRIV_KEY_PATH}" -o StrictHostKeyChecking=no /tmp/.dockerconfigjson ${BASTION_SSH_USER}@${BASTION_IP}:/tmp/config.json
ssh -o UserKnownHostsFile=/dev/null -o IdentityFile="${SSH_PRIV_KEY_PATH}" -o StrictHostKeyChecking=no ${BASTION_SSH_USER}@${BASTION_IP} \
    "sudo mkdir -p /tmp/tmp/.docker || true；
    sudo mv /tmp/config.json /tmp/tmp/.docker/config.json || true;
    sudo chown root:root /tmp/tmp/.docker/config.json || true;
    sudo chmod 600 /tmp/tmp/.docker/config.json || true;
    sudo ls -ltr /tmp/tmp/.docker/ || true"

res=$(oc get packagemanifests.packages.operators.coreos.com -l catalog=qe-app-registry -n $project || true)
if [ -z $res ]; then
    echo "The qe-app-registy catalogsource not exits!"
    exit 0
else
    internal=true
    catalog="qe-app-registry"
    echo "The catalog is $catalog"
fi
oc get packagemanifests.packages.operators.coreos.com -l catalog=$catalog -o json > /tmp/$catalog.json || true

#Below is a full test
package_list=$(cat /tmp/$catalog.json | jq '.items[].metadata.name' |sed 's/\"//g' || true)
echo "The package_list is: ${package_list}" || true
for package in ${package_list}; do
    echo "Starting scan for ${package}"
    mkdir "${data_dir}/${package}" || true
    skippedCSVs="compliance-operator.v0.1.32|compliance-operator.v0.1.61|file-integrity-operator.v0.1.13|file-integrity-operator.v0.1.32|file-integrity-operator.v1.0.0"
    currentCSVs=$(cat /tmp/$catalog.json | jq '.items[] | select(.metadata.name=="'${package}'").status.channels[].currentCSV'| uniq | grep -Ev $skippedCSVs || true);
    currentCSVs=${currentCSVs//\"/}
    for csv in ${currentCSVs}; do
        images_test_result="${data_dir}/${package}/$csv"
        echo "##Starting scan for csv ${csv}" >> $images_test_result
        image_list=$(cat /tmp/$catalog.json | jq '.items[].status.channels[]|select(.currentCSV=="'$csv'")|.currentCSVDesc.relatedImages[]' || true);
	    image_list=${image_list//,/}
	    image_list=${image_list//\"/}
        if $internal; then
            image_list=$(echo $image_list | sed -r 's/registry.redhat.io/brew.registry.redhat.io/g' )
            image_list=$(echo $image_list | sed -r 's/registry.stage.redhat.io/brew.registry.stage.redhat.io/g')
        fi
        for image_url in ${image_list}; do
            imges_test_result=$(ssh -o UserKnownHostsFile=/dev/null -o IdentityFile="${SSH_PRIV_KEY_PATH}" -o StrictHostKeyChecking=no ${BASTION_SSH_USER}@${BASTION_IP} \
                "sudo podman run --privileged -it -v /tmp/tmp/:/root/:ro registry.ci.openshift.org/ci/check-payload scan operator --spec $image_url" || true)
            echo "###test result for $image_url is: $imges_test_result" >> $images_test_result
        done
        echo "cat ${imges_test_result}" >> ${scan_result_file}
        resFail=$(grep -E "Failure Report" ${images_test_result} || true)
        resSuessWithWarnings=$(grep -E "Successful run with warnings" ${images_test_result} || true)
        if [[ -n $resFail ]];then
            echo "Fips check  for csv $csv in package $package failed!"
            echo "$csv" >> ${scan_result_failure_csvs}
            pass=false
        elif [[ -n $resSuessWithWarnings ]];then
            echo "Fips check  for csv $csv in package $package succeed with warnings!"
            echo "$csv" >> ${scan_result_succeed_with_warnings_csvs}
            pass=false
        else
            echo "Fips check for csv $csv in package $package succeed!"
        fi
        #delete containers and images to save disk space
        echo "delete containers"
        ssh -o UserKnownHostsFile=/dev/null -o IdentityFile="${SSH_PRIV_KEY_PATH}" -o StrictHostKeyChecking=no ${BASTION_SSH_USER}@${BASTION_IP} \
            "for container in \$(sudo podman ps -q -a); do sudo podman rm \${container} || true; done"
        echo "delete images"
        ssh -o UserKnownHostsFile=/dev/null -o IdentityFile="${SSH_PRIV_KEY_PATH}" -o StrictHostKeyChecking=no ${BASTION_SSH_USER}@${BASTION_IP} \
            "podman rmi $(echo ${image_list} | sed 's/\"//g') || true"
        echo "delete containers and images done"
    done
done

# print the compelete result
echo "The full result is: $(cat "${scan_result_file}" || true)"
echo "The fips check returned succeeded with warnings for below csvs: $(cat "${scan_result_succeed_with_warnings_csvs}" || true)"
echo "The csvs failed fips check are: $(cat "${scan_result_failure_csvs}" || true)"
tar -czC "${data_dir}" -f "${ARTIFACT_DIR}/fips-check-soptional_operators-images-scan.tar.gz" . || true
rm -rf "${data_dir}" || true

# check how much time used
time_used="$(( ($(date +%s) - $timestamp_start)/60 ))"
echo "Tests took ${time_used} minutes"

echo "Generating the Junit for fips check optional operators scan"
filename="fips-check-soptional_operators-images-scan"
testsuite="fips-check-soptional_operators-images-scan"
subteam="Security_and_Compliance"
if $pass; then
    cat >"${ARTIFACT_DIR}/${filename}.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="${testsuite}" failures="0" errors="0" skipped="0" tests="1" time="$SECONDS">
<testcase name="${subteam}:optional operators scan of fips check should succeedded or skipped"/>
</testsuite>
EOF
else
    cat >"${ARTIFACT_DIR}/${filename}.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="${testsuite}" failures="1" errors="0" skipped="0" tests="1" time="$SECONDS">
<testcase name="${subteam}:optional operators scan of fips check should succeedded or skipped">
<failure message="">Fips optional operators scan check failed</failure>
</testcase>
</testsuite>
EOF
fi
