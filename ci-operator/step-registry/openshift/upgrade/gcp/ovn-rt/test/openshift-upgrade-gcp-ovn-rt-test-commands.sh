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

if [[ $SKIP_REALTIME_SUITE == "true" ]]; then
    echo "Skipping the realtime suite because SKIP_REALTIME_SUITE was set"
    exit 0
fi

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

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

function cleanup() {
    echo "Requesting risk analysis for test failures in this job run from sippy:"
    openshift-tests risk-analysis --junit-dir "${ARTIFACT_DIR}/junit" || true

    echo "$(date +%s)" > "${SHARED_DIR}/TEST_TIME_TEST_END"
}
trap cleanup EXIT

mkdir -p "${HOME}"

# Override the upstream docker.io registry due to issues with rate limiting
# https://bugzilla.redhat.com/show_bug.cgi?id=1895107
# sjenning: TODO: use of personal repo is temporary; should find long term location for these mirrored images
export KUBE_TEST_REPO_LIST=${HOME}/repo_list.yaml
cat <<EOF > ${KUBE_TEST_REPO_LIST}
dockerLibraryRegistry: quay.io/sjenning
dockerGluster: quay.io/sjenning
EOF

# if the cluster profile included an insights secret, install it to the cluster to
# report support data from the support-operator
if [[ -f "${CLUSTER_PROFILE_DIR}/insights-live.yaml" ]]; then
    oc create -f "${CLUSTER_PROFILE_DIR}/insights-live.yaml" || true
fi

# if this test requires an SSH bastion and one is not installed, configure it
KUBE_SSH_BASTION="$( oc --insecure-skip-tls-verify get node -l node-role.kubernetes.io/master -o 'jsonpath={.items[0].status.addresses[?(@.type=="ExternalIP")].address}' ):22"
KUBE_SSH_KEY_PATH=${CLUSTER_PROFILE_DIR}/ssh-privatekey
export KUBE_SSH_BASTION KUBE_SSH_KEY_PATH

# set up cloud-provider-specific env vars
case "${CLUSTER_TYPE}" in
gcp)
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
ibmcloud)
    export TEST_PROVIDER='{"type":"ibmcloud"}'
    IC_API_KEY="$(< "${CLUSTER_PROFILE_DIR}/ibmcloud-api-key")"
    export IC_API_KEY
    ;;
nutanix) export TEST_PROVIDER='{"type":"nutanix"}' ;;
*) echo >&2 "Unsupported cluster type '${CLUSTER_TYPE}'"; exit 1;;
esac

mkdir -p /tmp/output
cd /tmp/output

if [[ "${CLUSTER_TYPE}" == gcp ]]; then
    pushd /tmp
    curl -O https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-sdk-256.0.0-linux-x86_64.tar.gz
    tar -xzf google-cloud-sdk-256.0.0-linux-x86_64.tar.gz
    export PATH=$PATH:/tmp/google-cloud-sdk/bin
    mkdir gcloudconfig
    export CLOUDSDK_CONFIG=/tmp/gcloudconfig
    gcloud auth activate-service-account --key-file="${GCP_SHARED_CREDENTIALS_FILE}"
    gcloud config set project "${PROJECT}"
    popd
fi

echo "$(date +%s)" > "${SHARED_DIR}/TEST_TIME_TEST_START"

oc -n openshift-config patch cm admin-acks --patch '{"data":{"ack-4.8-kube-1.22-api-removals-in-4.9":"true"}}' --type=merge || echo 'failed to ack the 4.9 Kube v1beta1 removals; possibly API-server issue, or a pre-4.8 release image'

# wait for ClusterVersion to level, until https://bugzilla.redhat.com/show_bug.cgi?id=2009845 makes it back to all 4.9 releases being installed in CI
oc wait --for=condition=Progressing=False --timeout=2m clusterversion/version

# wait up to 10m for the number of nodes to match the number of machines
i=0
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
    echo "$(date) - $MACHINECOUNT Machines - $NODECOUNT Nodes"
    sleep 30
    i=$((i+1))
    if [ $i -gt 20 ]; then
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

# this works around a problem where tests fail because imagestreams aren't imported.  We see this happen for exec session.
echo "$(date) - waiting for non-samples imagesteams to import..."
count=0
while :
do
  non_imported_imagestreams=$(oc -n openshift get imagestreams -o go-template='{{range .items}}{{$namespace := .metadata.namespace}}{{$name := .metadata.name}}{{range .status.tags}}{{if not .items}}{{$namespace}}/{{$name}}:{{.tag}}{{"\n"}}{{end}}{{end}}{{end}}')
  if [ -z "${non_imported_imagestreams}" ]
  then
    break
  fi
  echo "The following image streams are yet to be imported (attempt #${count}):"
  echo "${non_imported_imagestreams}"

  count=$((count+1))
  if (( count > 20 )); then
    echo "Failed while waiting on imagestream import"
    exit 1
  fi

  sleep 60
done
echo "$(date) - all imagestreams are imported."

set -x &&
openshift-tests run "openshift/nodes/realtime" \
    --provider "${TEST_PROVIDER}" \
    -o "${ARTIFACT_DIR}/e2e.log" \
    --junit-dir "${ARTIFACT_DIR}/junit" &
wait "$!" &&
set +x
