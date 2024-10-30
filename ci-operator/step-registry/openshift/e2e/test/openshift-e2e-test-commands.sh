#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export AWS_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/.awscred
export AZURE_AUTH_LOCATION=${CLUSTER_PROFILE_DIR}/osServicePrincipal.json
export GCP_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/gce.json
export ALIBABA_CLOUD_CREDENTIALS_FILE=${SHARED_DIR}/alibabacreds.ini
export HOME=/tmp/home
export PATH=/usr/libexec/origin:$PATH

echo "Debug artifact generation" > ${ARTIFACT_DIR}/dummy.log

# In order for openshift-tests to pull external binary images from the
# payload, we need access enabled to the images on the build farm. In
# order to do that, we need to unset the KUBECONFIG so we talk to the
# build farm, not the cluster under test.
echo "Granting access for image pulling from the build farm..."
KUBECONFIG_BAK=$KUBECONFIG
unset KUBECONFIG
oc adm policy add-role-to-group system:image-puller system:unauthenticated --namespace "${NAMESPACE}"
export KUBECONFIG=$KUBECONFIG_BAK

# HACK: HyperShift clusters use their own profile type, but the cluster type
# underneath is actually AWS and the type identifier is derived from the profile
# type. For now, just treat the `hypershift` type the same as `aws` until
# there's a clean way to decouple the notion of a cluster provider and the
# platform type.
#
# See also: https://issues.redhat.com/browse/DPTP-1988
if [[ "${CLUSTER_TYPE}" == "hypershift" ]]; then
    export CLUSTER_TYPE="aws"
    echo "Overriding 'hypershift' cluster type to be 'aws'"
fi

# For disconnected or otherwise unreachable environments, we want to
# have steps use an HTTP(S) proxy to reach the API server. This proxy
# configuration file should export HTTP_PROXY, HTTPS_PROXY, and NO_PROXY
# environment variables, as well as their lowercase equivalents (note
# that libcurl doesn't recognize the uppercase variables).
if test -f "${SHARED_DIR}/proxy-conf.sh"
then
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
fi

# OpenShift clusters intalled with platform type External is handled as 'None'
# by the e2e framework, even through it was installed in an infrastructure (CLUSTER_TYPE)
# integrated by OpenShift (like AWS).
STATUS_PLATFORM_NAME="$(oc get Infrastructure cluster -o jsonpath='{.status.platform}' || true)"
if [[ "${STATUS_PLATFORM_NAME-}" == "External" ]]; then
    export CLUSTER_TYPE="external"
fi

if [[ -n "${TEST_CSI_DRIVER_MANIFEST}" ]]; then
    export TEST_CSI_DRIVER_FILES=${SHARED_DIR}/${TEST_CSI_DRIVER_MANIFEST}
fi
if [[ -n "${TEST_OCP_CSI_DRIVER_MANIFEST}" ]] && [[ -e "${SHARED_DIR}/${TEST_OCP_CSI_DRIVER_MANIFEST}" ]]; then
    export TEST_OCP_CSI_DRIVER_FILES=${SHARED_DIR}/${TEST_OCP_CSI_DRIVER_MANIFEST}
fi

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

function cleanup() {
    echo "Requesting risk analysis for test failures in this job run from sippy:"
    openshift-tests risk-analysis --junit-dir "${ARTIFACT_DIR}/junit" || true

    echo "$(date +%s)" > "${SHARED_DIR}/TEST_TIME_TEST_END"
}
trap cleanup EXIT

mkdir -p "${HOME}"

# if the cluster profile included an insights secret, install it to the cluster to
# report support data from the support-operator
if [[ -f "${CLUSTER_PROFILE_DIR}/insights-live.yaml" ]]; then
    oc create -f "${CLUSTER_PROFILE_DIR}/insights-live.yaml" || true
fi

# if this test requires an SSH bastion and one is not installed, configure it
KUBE_SSH_BASTION="$( oc --insecure-skip-tls-verify get node -l node-role.kubernetes.io/master -o 'jsonpath={.items[0].status.addresses[?(@.type=="ExternalIP")].address}' ):22"
KUBE_SSH_KEY_PATH=${CLUSTER_PROFILE_DIR}/ssh-privatekey
export KUBE_SSH_BASTION KUBE_SSH_KEY_PATH
if [[ -n "${TEST_REQUIRES_SSH-}" ]]; then
    export SSH_BASTION_NAMESPACE=test-ssh-bastion
    echo "Setting up ssh bastion"

    # configure the local container environment to have the correct SSH configuration
    mkdir -p ~/.ssh
    cp "${KUBE_SSH_KEY_PATH}" ~/.ssh/id_rsa
    chmod 0600 ~/.ssh/id_rsa
    if ! whoami &> /dev/null; then
        if [[ -w /etc/passwd ]]; then
            echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >> /etc/passwd
        fi
    fi

    # if this is run from a flow that does not have the ssh-bastion step, deploy the bastion
    if ! oc get -n "${SSH_BASTION_NAMESPACE}" ssh-bastion; then
        curl https://raw.githubusercontent.com/eparis/ssh-bastion/master/deploy/deploy.sh | bash -x
    fi

    # locate the bastion host for use within the tests
    for _ in $(seq 0 30); do
        # AWS fills only .hostname of a service
        BASTION_HOST=$(oc get service -n "${SSH_BASTION_NAMESPACE}" ssh-bastion -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
        if [[ -n "${BASTION_HOST}" ]]; then break; fi
        # Azure fills only .ip of a service. Use it as bastion host.
        BASTION_HOST=$(oc get service -n "${SSH_BASTION_NAMESPACE}" ssh-bastion -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
        if [[ -n "${BASTION_HOST}" ]]; then break; fi
        echo "Waiting for SSH bastion load balancer service"
        sleep 10
    done
    if [[ -z "${BASTION_HOST}" ]]; then
        echo >&2 "Failed to find bastion address, exiting"
        exit 1
    fi
    export KUBE_SSH_BASTION="${BASTION_HOST}:22"
fi

if [[ -f "${SHARED_DIR}/mirror-tests-image" ]]; then
    TEST_ARGS="${TEST_ARGS:-}"
    TEST_ARGS+=" --from-repository=$(<"${SHARED_DIR}/mirror-tests-image")"
fi

# set up cloud-provider-specific env vars
case "${CLUSTER_TYPE}" in
gcp|gcp-arm64)
    export GOOGLE_APPLICATION_CREDENTIALS="${GCP_SHARED_CREDENTIALS_FILE}"
    # In k8s 1.24 this is required to run GCP PD tests. See: https://github.com/kubernetes/kubernetes/pull/109541
    export ENABLE_STORAGE_GCE_PD_DRIVER="yes"
    export KUBE_SSH_USER=core
    mkdir -p ~/.ssh
    cp "${CLUSTER_PROFILE_DIR}/ssh-privatekey" ~/.ssh/google_compute_engine || true
    # TODO: make openshift-tests auto-discover this from cluster config
    PROJECT="$(oc get -o jsonpath='{.status.platformStatus.gcp.projectID}' infrastructure cluster)"
    REGION="$(oc get -o jsonpath='{.status.platformStatus.gcp.region}' infrastructure cluster)"
    export TEST_PROVIDER="{\"type\":\"gce\",\"region\":\"${REGION}\",\"multizone\": true,\"multimaster\":true,\"projectid\":\"${PROJECT}\"}"
    ;;
aws|aws-arm64)
    mkdir -p ~/.ssh
    cp "${CLUSTER_PROFILE_DIR}/ssh-privatekey" ~/.ssh/kube_aws_rsa || true
    export PROVIDER_ARGS="-provider=aws -gce-zone=us-east-1"
    # TODO: make openshift-tests auto-discover this from cluster config
    REGION="$(oc get -o jsonpath='{.status.platformStatus.aws.region}' infrastructure cluster)"
    ZONE="$(oc get -o jsonpath='{.items[0].metadata.labels.failure-domain\.beta\.kubernetes\.io/zone}' nodes)"
    export TEST_PROVIDER="{\"type\":\"aws\",\"region\":\"${REGION}\",\"zone\":\"${ZONE}\",\"multizone\":true,\"multimaster\":true}"
    export KUBE_SSH_USER=core
    ;;
azure4|azure-arm64) export TEST_PROVIDER=azure;;
azurestack)
    export TEST_PROVIDER="none"
    export AZURE_AUTH_LOCATION=${SHARED_DIR}/osServicePrincipal.json
    export SSL_CERT_FILE="${CLUSTER_PROFILE_DIR}/ca.pem"
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
alibabacloud)
    mkdir -p ~/.ssh
    cp "${CLUSTER_PROFILE_DIR}/ssh-privatekey" ~/.ssh/kube_alibaba_rsa || true
    export PROVIDER_ARGS="-provider=alibabacloud -gce-zone=us-east-1"
    # TODO: make openshift-tests auto-discover this from cluster config
    REGION="$(oc get -o jsonpath='{.status.platformStatus.alibabacloud.region}' infrastructure cluster)"
    export TEST_PROVIDER="{\"type\":\"alibabacloud\",\"region\":\"${REGION}\",\"multizone\":true,\"multimaster\":true}"
    export KUBE_SSH_USER=core
;;
openstack*)
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/cinder_credentials.sh"
    if test -n "${HTTP_PROXY:-}" -o -n "${HTTPS_PROXY:-}"; then
        export TEST_PROVIDER='{"type":"openstack","disconnected":true}'
    else
        export TEST_PROVIDER='{"type":"openstack"}'
    fi
    ;;
ovirt) export TEST_PROVIDER='{"type":"ovirt"}';;
ibmcloud*)
    export TEST_PROVIDER='{"type":"ibmcloud"}'
    IC_API_KEY="$(< "${CLUSTER_PROFILE_DIR}/ibmcloud-api-key")"
    export IC_API_KEY
    ;;
powervs*)
    #export TEST_PROVIDER='{"type":"powervs"}' # TODO In the future, powervs will be a supprted test type
    export TEST_PROVIDER='{"type":"ibmcloud"}'
    IC_API_KEY=$(sed -e 's,^.*"apikey":",,' -e 's,".*$,,' ${SHARED_DIR}/powervs-config.json)
    IBMCLOUD_API_KEY=${IC_API_KEY}
    export IC_API_KEY
    export IBMCLOUD_API_KEY
    ;;
nutanix) export TEST_PROVIDER='{"type":"nutanix"}' ;;
external) export TEST_PROVIDER='' ;;
*) echo >&2 "Unsupported cluster type '${CLUSTER_TYPE}'"; exit 1;;
esac

mkdir -p /tmp/output
cd /tmp/output

if [[ "${CLUSTER_TYPE}" == "gcp" || "${CLUSTER_TYPE}" == "gcp-arm64"  ]]; then
    pushd /tmp
    curl -O https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-sdk-318.0.0-linux-x86_64.tar.gz
    tar -xzf google-cloud-sdk-318.0.0-linux-x86_64.tar.gz
    export PATH=$PATH:/tmp/google-cloud-sdk/bin
    mkdir gcloudconfig
    export CLOUDSDK_CONFIG=/tmp/gcloudconfig
    gcloud auth activate-service-account --key-file="${GCP_SHARED_CREDENTIALS_FILE}"
    gcloud config set project "${PROJECT}"
    popd
fi

# Preserve the && chaining in this function, because it is called from and AND-OR list so it doesn't get errexit.
function upgrade() {
    set -x &&
    TARGET_RELEASES="${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE:-}" &&
    if [[ -f "${SHARED_DIR}/override-upgrade" ]]; then
        TARGET_RELEASES="$(< "${SHARED_DIR}/override-upgrade")" &&
        echo "Overriding upgrade target to ${TARGET_RELEASES}"
    fi &&
    openshift-tests run-upgrade "${TEST_UPGRADE_SUITE}" \
        --to-image "${TARGET_RELEASES}" \
        --options "${TEST_UPGRADE_OPTIONS-}" \
        --provider "${TEST_PROVIDER}" \
        -o "${ARTIFACT_DIR}/e2e.log" \
        --junit-dir "${ARTIFACT_DIR}/junit" &
    wait "$!" &&
    set +x
}

# upgrade_conformance runs the upgrade and the parallel tests, and exits with an error if either fails.
function upgrade_conformance() {
    local exit_code=0 &&
    upgrade || exit_code=$? &&
    PROGRESSING="$(oc get -o jsonpath='{.status.conditions[?(@.type == "Progressing")].status}' clusterversion version)" &&
    HISTORY_LENGTH="$(oc get -o jsonpath='{range .status.history[*]}{.version}{"\n"}{end}' clusterversion version | wc -l)" &&
    if test 2 -gt "${HISTORY_LENGTH}"
    then
        echo "Skipping conformance suite because ClusterVersion only has ${HISTORY_LENGTH} entries, so an update was not run"
    elif test False != "${PROGRESSING}"
    then
        echo "Skipping conformance suite because post-update ClusterVersion Progressing=${PROGRESSING}"
    else
        TEST_LIMIT_START_TIME="$(date +%s)" TEST_SUITE=openshift/conformance/parallel suite || exit_code=$?
    fi &&
    return $exit_code
}

# upgrade_rt runs the rt test suite, the upgrade, and the rt test suite again, and exits with an error if any calls fail
function upgrade_rt() {
    local exit_code=0 &&
    TEST_SUITE=openshift/nodes/realtime suite || exit_code=$? &&
    upgrade || exit_code=$? &&
    TEST_SUITE=openshift/nodes/realtime suite || exit_code=$? &&
    return $exit_code
}

function upgrade_paused() {
    set -x
    unset TEST_SUITE
    TARGET_RELEASES="${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE:-}"
    if [[ -f "${SHARED_DIR}/override-upgrade" ]]; then
        TARGET_RELEASES="$(< "${SHARED_DIR}/override-upgrade")"
        echo "Overriding upgrade target to ${TARGET_RELEASES}"
    fi
    # Split TARGET_RELEASES by commas, producing two releases
    OPENSHIFT_UPGRADE0_RELEASE_IMAGE_OVERRIDE="$(echo $TARGET_RELEASES | cut -f1 -d,)"
    OPENSHIFT_UPGRADE1_RELEASE_IMAGE_OVERRIDE="$(echo $TARGET_RELEASES | cut -f2 -d,)"

    oc patch mcp/worker --type merge --patch '{"spec":{"paused":true}}'

    echo "Starting control-plane upgrade to ${OPENSHIFT_UPGRADE0_RELEASE_IMAGE_OVERRIDE}"
    openshift-tests run-upgrade "${TEST_UPGRADE_SUITE}" \
        --to-image "${OPENSHIFT_UPGRADE0_RELEASE_IMAGE_OVERRIDE}" \
        --options "${TEST_UPGRADE_OPTIONS-}" \
        --provider "${TEST_PROVIDER}" \
        -o "${ARTIFACT_DIR}/e2e.log" \
        --junit-dir "${ARTIFACT_DIR}/junit" &
    wait "$!"
    echo "Upgraded control-plane to ${OPENSHIFT_UPGRADE0_RELEASE_IMAGE_OVERRIDE}"

    echo "Starting control-plane upgrade to ${OPENSHIFT_UPGRADE1_RELEASE_IMAGE_OVERRIDE}"
    openshift-tests run-upgrade "${TEST_UPGRADE_SUITE}" \
        --to-image "${OPENSHIFT_UPGRADE1_RELEASE_IMAGE_OVERRIDE}" \
        --options "${TEST_UPGRADE_OPTIONS-}" \
        --provider "${TEST_PROVIDER}" \
        -o "${ARTIFACT_DIR}/e2e.log" \
        --junit-dir "${ARTIFACT_DIR}/junit" &
    wait "$!"
    echo "Upgraded control-plane to ${OPENSHIFT_UPGRADE1_RELEASE_IMAGE_OVERRIDE}"

    echo "Starting worker upgrade to ${OPENSHIFT_UPGRADE1_RELEASE_IMAGE_OVERRIDE}"
    oc patch mcp/worker --type merge --patch '{"spec":{"paused":false}}'
    openshift-tests run-upgrade all \
        --to-image "${OPENSHIFT_UPGRADE1_RELEASE_IMAGE_OVERRIDE}" \
        --options "${TEST_UPGRADE_OPTIONS-}" \
        --provider "${TEST_PROVIDER}" \
        -o "${ARTIFACT_DIR}/e2e.log" \
        --junit-dir "${ARTIFACT_DIR}/junit" &
    wait "$!"
    echo "Upgraded workers to ${OPENSHIFT_UPGRADE1_RELEASE_IMAGE_OVERRIDE}"
    set +x
}


# Preserve the && chaining in this function, because it is called from and AND-OR list so it doesn't get errexit.
function suite() {
    if [[ -n "${TEST_SKIPS}" ]]; then
        TESTS="$(openshift-tests run --dry-run --provider "${TEST_PROVIDER}" "${TEST_SUITE}")" &&
        echo "${TESTS}" | grep -v "${TEST_SKIPS}" >/tmp/tests &&
        echo "Skipping tests:" &&
        echo "${TESTS}" | grep "${TEST_SKIPS}" || { exit_code=$?; echo 'Error: no tests were found matching the TEST_SKIPS regex:'; echo "$TEST_SKIPS"; return $exit_code; } &&
        TEST_ARGS="${TEST_ARGS:-} --file /tmp/tests"
    fi &&

    set -x &&
    openshift-tests run "${TEST_SUITE}" ${TEST_ARGS:-} \
        --provider "${TEST_PROVIDER}" \
        -o "${ARTIFACT_DIR}/e2e.log" \
        --junit-dir "${ARTIFACT_DIR}/junit" &
    wait "$!" &&
    set +x
}

echo "$(date +%s)" > "${SHARED_DIR}/TEST_TIME_TEST_START"

oc -n openshift-config patch cm admin-acks --patch '{"data":{"ack-4.8-kube-1.22-api-removals-in-4.9":"true"}}' --type=merge || echo 'failed to ack the 4.9 Kube v1beta1 removals; possibly API-server issue, or a pre-4.8 release image'

# wait for ClusterVersion to level, until https://bugzilla.redhat.com/show_bug.cgi?id=2009845 makes it back to all 4.9 releases being installed in CI
oc wait --for=condition=Progressing=False --timeout=2m clusterversion/version

# wait up to 10m for the number of nodes to match the number of machines
i=0
node_check_interval=30
node_check_limit=20
# AWS Local Zone nodes usually take much more to be ready.
test -n "${AWS_EDGE_POOL_ENABLED-}" && node_check_limit=60
while true
do
    MACHINECOUNT="$(kubectl get machines -A --no-headers | wc -l)"
    NODECOUNT="$(kubectl get nodes --no-headers | wc -l)"
    if [ "${MACHINECOUNT}" -le "${NODECOUNT}" ]
    then
      cat >"${ARTIFACT_DIR}/junit_nodes.xml" <<EOF
      <testsuite name="cluster nodes" tests="1" failures="0">
        <testcase name="node count should match or exceed machine count"/>
      </testsuite>
EOF
        echo "$(date) - node count ($NODECOUNT) now matches or exceeds machine count ($MACHINECOUNT)"
        break
    fi
    echo "$(date) [$i/$node_check_limit] - $MACHINECOUNT Machines - $NODECOUNT Nodes"
    sleep $node_check_interval
    i=$((i+1))
    if [ $i -gt $node_check_limit ]; then
      MACHINELIST="$(kubectl get machines -A)"
      NODELIST="$(kubectl get nodes)"
      cat >"${ARTIFACT_DIR}/junit_nodes.xml" <<EOF
      <testsuite name="cluster nodes" tests="1" failures="1">
        <testcase name="node count should match or exceed machine count">
          <failure message="">
            Timed out waiting for node count ($NODECOUNT) to equal or exceed machine count ($MACHINECOUNT).
            $MACHINELIST
            $NODELIST
          </failure>
        </testcase>
      </testsuite>
EOF

        echo "Timed out waiting for node count ($NODECOUNT) to equal or exceed machine count ($MACHINECOUNT)."
        # If we enabled the ssh bastion pod, attempt to gather journal logs from each machine, regardless
        # if it made it to a node or not.
        if [[ -n "${TEST_REQUIRES_SSH-}" ]]; then
            echo "Attempting to gather system journal logs from each machine via ssh bastion pod"
            mkdir -p "${ARTIFACT_DIR}/ssh-bastion-gather/"

            # This returns each IP all on one line, separated by spaces:
            machine_ips="$(oc --insecure-skip-tls-verify get machines -n openshift-machine-api -o 'jsonpath={.items[*].status.addresses[?(@.type=="InternalIP")].address}')"
            echo "Found machine IPs: $machine_ips"
            ingress_host="$(oc get service --all-namespaces -l run=ssh-bastion -o go-template='{{ with (index (index .items 0).status.loadBalancer.ingress 0) }}{{ or .hostname .ip }}{{end}}')"
            echo "Ingress host: $ingress_host"

            # Disable errors so we keep trying hosts if any of these commands fail.
            set +e
            for ip in $machine_ips
            do
                echo "Gathering journalctl logs from ${ip}"
                ssh -i "${KUBE_SSH_KEY_PATH}" -o StrictHostKeyChecking=no -o ProxyCommand="ssh -i ${KUBE_SSH_KEY_PATH} -A -o StrictHostKeyChecking=no -o ServerAliveInterval=30 -W %h:%p core@${ingress_host}" core@$ip "sudo journalctl --no-pager" > "${ARTIFACT_DIR}/ssh-bastion-gather/${ip}-journal.log"
                ssh -i "${KUBE_SSH_KEY_PATH}" -o StrictHostKeyChecking=no -o ProxyCommand="ssh -i ${KUBE_SSH_KEY_PATH} -A -o StrictHostKeyChecking=no -o ServerAliveInterval=30 -W %h:%p core@${ingress_host}" core@$ip "sudo /sbin/ip addr show" > "${ARTIFACT_DIR}/ssh-bastion-gather/${ip}-ip-addr-show.log"
                ssh -i "${KUBE_SSH_KEY_PATH}" -o StrictHostKeyChecking=no -o ProxyCommand="ssh -i ${KUBE_SSH_KEY_PATH} -A -o StrictHostKeyChecking=no -o ServerAliveInterval=30 -W %h:%p core@${ingress_host}" core@$ip "sudo /sbin/ip route show" > "${ARTIFACT_DIR}/ssh-bastion-gather/${ip}-ip-route-show.log"
            done
            set -e
        fi

        exit 1
    fi
done

# wait for all nodes to reach Ready=true to ensure that all machines and nodes came up, before we run
# any e2e tests that might require specific workload capacity.
echo "$(date) - waiting for nodes to be ready..."
ret=0
oc wait nodes --all --for=condition=Ready=true --timeout=10m || ret=$?
if [[ "$ret" == 0 ]]; then
      cat >"${ARTIFACT_DIR}/junit_node_ready.xml" <<EOF
      <testsuite name="cluster nodes ready" tests="1" failures="0">
        <testcase name="all nodes should be ready"/>
      </testsuite>
EOF
    echo "$(date) - all nodes are ready"
else
    set +e
    getNodeResult=$(oc get nodes)
    set -e
    cat >"${ARTIFACT_DIR}/junit_node_ready.xml" <<EOF
    <testsuite name="cluster nodes ready" tests="1" failures="1">
      <testcase name="all nodes should be ready">
        <failure message="">
          Timed out waiting for nodes to be ready. Return code: $ret.
          oc get nodes
          $getNodeResult
        </failure>
      </testcase>
    </testsuite>
EOF
    echo "Timed out waiting for nodes to be ready. Return code: $ret."
    exit 1
fi

# wait for all clusteroperators to reach progressing=false to ensure that we achieved the configuration specified at installation
# time before we run our e2e tests.
echo "$(date) - waiting for clusteroperators to finish progressing..."
oc wait clusteroperators --all --for=condition=Progressing=false --timeout=10m
echo "$(date) - all clusteroperators are done progressing."

# reportedly even the above is not enough for etcd which can still require time to stabilize and rotate certs.
# wait longer if the new command is available, but it won't be present in past releases.
echo "$(date) - waiting for oc adm wait-for-stable-cluster..."
if oc adm wait-for-stable-cluster --minimum-stable-period 2m &>/dev/null; then
	echo "$(date) - oc adm reports cluster is stable."
else
	echo "$(date) - oc adm wait-for-stable-cluster is not available in this release"
fi


# this works around a problem where tests fail because imagestreams aren't imported.  We see this happen for exec session.
count=1
while :
do
  echo "[$(date)] waiting for non-samples imagesteams to import..."
  wait_count=1
  while :
  do
    non_imported_imagestreams=$(oc -n openshift get imagestreams -o go-template='{{range .items}}{{$namespace := .metadata.namespace}}{{$name := .metadata.name}}{{range .status.tags}}{{if not .items}}{{$namespace}}/{{$name}}:{{.tag}}{{"\n"}}{{end}}{{end}}{{end}}')
    if [ -z "${non_imported_imagestreams}" ]
    then
      break 2 # break from outer loop
    fi
    echo "[$(date)] The following image streams are yet to be imported (attempt #${wait_count}):"
    echo "${non_imported_imagestreams}"

    wait_count=$((wait_count+1))
    if (( wait_count > 10 )); then
        break
    fi

    sleep 60
  done

  # Given up after 3 rounds of waiting 10 minutes
  count=$((count+1))
  if (( count > 3 )); then
      echo "[$(date)] Failed to import all image streams after 30 minutes"
      echo $non_imported_imagestreams
      exit 1
  fi

  # image streams won't retry by themselves https://issues.redhat.com/browse/RFE-3660
  set +e
  for imagestream in $non_imported_imagestreams
  do
      echo "[$(date)] Retrying image import $imagestream"
      oc import-image --insecure=true -n "$(echo "$imagestream" | cut -d/ -f1)" "$(echo "$imagestream" | cut -d/ -f2)"
  done
  set -e
done

echo "[$(date)] All imagestreams are imported."

case "${TEST_TYPE}" in
upgrade-conformance)
    upgrade_conformance
    ;;
upgrade)
    upgrade
    ;;
upgrade-paused)
    upgrade_paused
    ;;
upgrade-rt)
    upgrade_rt
    ;;
suite-conformance)
    suite
    TEST_LIMIT_START_TIME="$(date +%s)" TEST_SUITE=openshift/conformance/parallel suite
    ;;
suite)
    suite
    ;;
*)
    echo >&2 "Unsupported test type '${TEST_TYPE}'"
    exit 1
    ;;
esac
