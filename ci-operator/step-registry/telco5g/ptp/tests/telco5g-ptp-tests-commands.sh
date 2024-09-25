#!/bin/bash

set -x
set -o nounset
set -o errexit
set -o pipefail

build_images(){
oc delete namespace openshift-ptp || true
oc create namespace openshift-ptp -o yaml | oc label -f - pod-security.kubernetes.io/enforce=privileged pod-security.kubernetes.io/audit=privileged pod-security.kubernetes.io/warn=privileged || true
# copy pull secrets in openshift-ptp namespace
oc get secret pull-secret --namespace=openshift-config -oyaml | grep -v '^\s*namespace:\s' | oc apply --namespace=openshift-ptp -f -
echo $KUBECONFIG
jobdefinition='---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: privileged-rights
  namespace: openshift-ptp
rules:
- apiGroups:
  - security.openshift.io
  resourceNames:
  - privileged
  resources:
  - securitycontextconstraints
  verbs:
  - use
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  managedFields:
  name: privileged-rights
  namespace: openshift-ptp
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: privileged-rights
subjects:
- kind: ServiceAccount
  name: builder
  namespace: openshift-ptp
---
apiVersion: v1
kind: Pod
metadata:
  name: podman
  namespace: openshift-ptp
spec:
  restartPolicy: Never
  serviceAccountName: builder
  containers:
    - name: priv
      image: quay.io/podman/stable
      command:
        - /bin/bash
        - -c
        - |
          set -xe
          yum install jq git wget podman-docker -y
          yum groupinstall "Development Tools" -y
          wget https://go.dev/dl/go1.20.4.linux-amd64.tar.gz
          rm -rf /usr/local/go && tar -C /usr/local -xzf go1.20.4.linux-amd64.tar.gz
          export PATH=$PATH:/usr/local/go/bin
          go version

          # set +x here to hide pass from log
          set +xe

          echo "podman login with serviceaccount"

          # Used for 4.16 and newer releases.
          pass=$( jq .\"image-registry.openshift-image-registry.svc:5000\".auth /var/run/secrets/openshift.io/push/.dockercfg )
          pass=`echo ${pass:1:-1} | base64 -d`
          podman login -u serviceaccount -p ${pass:8} image-registry.openshift-image-registry.svc:5000 --tls-verify=false

          # Used for 4.15 and older releases.
          if ! podman login --get-login image-registry.openshift-image-registry.svc:5000 &> /dev/null; then
            pass=$( jq .\"image-registry.openshift-image-registry.svc:5000\".password /var/run/secrets/openshift.io/push/.dockercfg )
            podman login -u serviceaccount -p ${pass:1:-1} image-registry.openshift-image-registry.svc:5000 --tls-verify=false
          fi

          set -x

          git clone --single-branch --branch OPERATOR_VERSION https://github.com/openshift/ptp-operator.git
          cd ptp-operator
          export IMG=PTP_IMAGE
          sed -i "/ENV GO111MODULE=off/ a\ENV GOMAXPROCS=20" Dockerfile
          make docker-build
          podman push ${IMG} --tls-verify=false
          cd ..
      securityContext:
        privileged: true
      volumeMounts:
        - mountPath: /var/run/secrets/openshift.io/push
          name: dockercfg
          readOnly: true
        - name: secret-volume
          mountPath: /root/.docker

  volumes:
    - name: secret-volume
      secret:
        secretName: pull-secret
        items:
        - key: .dockerconfigjson
          path: config.json

    - name: dockercfg
      defaultMode: 384
      secret:
      '

jobdefinition=$(sed "s#OPERATOR_VERSION#${PTP_UNDER_TEST_BRANCH}#" <<< "$jobdefinition")
jobdefinition=$(sed "s#PTP_IMAGE#${IMG}#" <<< "$jobdefinition")
#oc label ns openshift-ptp --overwrite pod-security.kubernetes.io/enforce=privileged

retry_with_timeout 400 5 oc -n openshift-ptp get sa builder
dockercgf=$(oc -n openshift-ptp get sa builder -oyaml | grep imagePullSecrets -A 1 | grep -o "builder-.*")
jobdefinition="${jobdefinition} secretName: ${dockercgf}"
echo "$jobdefinition"
echo "$jobdefinition" | oc apply -f -

success=0
iterations=0
sleep_time=10
max_iterations=72 # results in 12 minutes timeout
until [[ $success -eq 1 ]] || [[ $iterations -eq $max_iterations ]]
do
  run_status=$(oc -n openshift-ptp get pod podman -o json | jq '.status.phase' | tr -d '"')
   if [ "$run_status" == "Succeeded" ]; then
          success=1
          break
   fi
   iterations=$((iterations+1))
   sleep $sleep_time
done

if [[ $success -eq 1 ]]; then
  echo "[INFO] index build succeeded"
else
  echo "[ERROR] index build failed"
  exit 1
fi

# print the build logs
oc -n openshift-ptp logs podman

}

# Define the function to retry a command with a timeout
retry_with_timeout() {
  local timeout=$1
  local interval=$2
  local command="${*:3}"
  echo command=$command
  local start_time
  start_time=$(date +%s)
  local end_time=$((start_time + timeout))
  while true; do
    # Run the command
    ${command} && return 0

    # Check if the timeout has expired
    local current_time
    current_time=$(date +%s)
    if [ ${current_time} -gt ${end_time} ]; then
      return 1
    fi

    # Sleep for the specified interval before retrying
    sleep ${interval}
  done
}

# print RTC logs
print_time() {
# Get the list of nodes in the cluster
NODES=$(oc get nodes -l node-role.kubernetes.io/worker -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')

# Loop through each node
for node in $NODES; do
    echo "Processing node: $node"
    oc debug node/$node -- chroot /host sh -c "date;sudo hwclock"
done
}

set_events_output_file() {
  sed -i -E 's@(event_output_file:\s*)(.*)@event_output_file: '${ARTIFACT_DIR}'/event_log_'${PTP_TEST_MODE}'.csv@g' ${SHARED_DIR}/test-config.yaml
}

echo "************ telco5g cnf-tests commands ************"

if [[ -n "${E2E_TESTS_CONFIG:-}" ]]; then
    readarray -t config <<< "${E2E_TESTS_CONFIG}"
    for var in "${config[@]}"; do
        if [[ ! -z "${var}" ]]; then
            if [[ "${var}" == *"CNF_E2E_TESTS"* ]]; then
                CNF_E2E_TESTS="$(echo "${var}" | cut -d'=' -f2)"
            elif [[ "${var}" == *"CNF_ORIGIN_TESTS"* ]]; then
                CNF_ORIGIN_TESTS="$(echo "${var}" | cut -d'=' -f2)"
            fi
        fi
    done
fi

export CNF_E2E_TESTS
export CNF_ORIGIN_TESTS
# always use the latest test code
export TEST_BRANCH="master"

export PTP_UNDER_TEST_BRANCH="release-${T5CI_VERSION}"
export IMG_VERSION="release-${T5CI_VERSION}"

export KUBECONFIG=$SHARED_DIR/kubeconfig

# Set go version
if [[ "$T5CI_VERSION" =~ 4.1[2-5]+ ]]; then
    source $HOME/golang-1.20
elif [[ "$T5CI_VERSION" == "4.16" ]]; then
    source $HOME/golang-1.21.11
else
    source $HOME/golang-1.22.4
fi

temp_dir=$(mktemp -d -t cnf-XXXXX)
cd "$temp_dir" || exit 1

# deploy ptp
echo "deploying ptp-operator on branch ${PTP_UNDER_TEST_BRANCH}"

# build ptp operator and create catalog
export IMG=image-registry.openshift-image-registry.svc:5000/openshift-ptp/ptp-operator:${T5CI_VERSION}
build_images

# deploy ptp-operator

git clone https://github.com/openshift/ptp-operator.git -b "${PTP_UNDER_TEST_BRANCH}" ptp-operator-under-test

cd ptp-operator-under-test

# force downloading fresh images
grep -r "imagePullPolicy: IfNotPresent" --files-with-matches | awk '{print  "sed -i -e \"s@imagePullPolicy: IfNotPresent@imagePullPolicy: Always@g\" " $1 }' | bash

# deploy ptp-operator
make deploy

# wait until the linuxptp-daemon pods are ready
retry_with_timeout 400 5 kubectl rollout status daemonset linuxptp-daemon -nopenshift-ptp

# patching to add events
#TODOv2 update after v2 backport to 4.16
#if [[ "$T5CI_VERSION" =~ 4.1[2-5]+ ]]; then
if [[ "$T5CI_VERSION" =~ 4.1[2-6]+ ]]; then
    export EVENT_API_VERSION="1.0"
    oc patch ptpoperatorconfigs.ptp.openshift.io default -nopenshift-ptp --patch '{"spec":{"ptpEventConfig":{"enableEventPublisher":true, "storageType":"emptyDir"}, "daemonNodeSelector": {"node-role.kubernetes.io/worker":""}}}' --type=merge
else
    export EVENT_API_VERSION="2.0"
    oc patch ptpoperatorconfigs.ptp.openshift.io default -nopenshift-ptp --patch '{"spec":{"ptpEventConfig":{"enableEventPublisher":true, "apiVersion":"2.0"}, "daemonNodeSelector": {"node-role.kubernetes.io/worker":""}}}' --type=merge
fi

#TODOv2 update after v2 backport to 4.16
#if [[ "$T5CI_VERSION" =~ 4.1[6-7]+ ]]; then
if [[ "$T5CI_VERSION" =~ 4.1[7]+ ]]; then
    export ENABLE_V1_REGRESSION="true"
else
    export ENABLE_V1_REGRESSION="false"
fi

# wait for the linuxptp-daemon to be deployed
retry_with_timeout 400 5 kubectl rollout status daemonset linuxptp-daemon -nopenshift-ptp

# Run ptp conformance test
cd -
echo "running conformance tests from branch ${TEST_BRANCH}"
git clone https://github.com/openshift/ptp-operator.git -b "${TEST_BRANCH}" ptp-operator-conformance-test

cd ptp-operator-conformance-test

# configuration
cat <<'EOF' > ${SHARED_DIR}/test-config.yaml
---
global:
 maxoffset: 100
 minoffset: -100
soaktest:
  disable_all: false
  event_output_file: "./event-output.csv"
  duration: 10
  failure_threshold: 2
  master_offset:
    spec:
      enable: true
      duration: 10
      failure_threshold: 20
    desc: "This test measures the master offset check"
  slave_clock_sync:
    spec:
      enable: true
      duration: 5
      failure_threshold: 1
    desc: "The test measures number of PTP time sync faults, and fails if > failure_threshold"
  cpu_utilization:
    spec:
      enable: true
      duration: 5
      failure_threshold: 3
      custom_params:
        prometheus_rate_time_window: "70s"
        node:
          cpu_threshold_mcores: 100
        pod:
          - pod_type: "ptp-operator"
            cpu_threshold_mcores: 30

          - pod_type: "linuxptp-daemon"
            cpu_threshold_mcores: 80

          - pod_type: "linuxptp-daemon"
            container: "cloud-event-proxy"
            cpu_threshold_mcores: 30

          - pod_type: "linuxptp-daemon"
            container: "linuxptp-daemon-container"
            cpu_threshold_mcores: 40
    desc: "The test measures PTP CPU usage and fails if >15mcores"
EOF

# Set output directory
export JUNIT_OUTPUT_DIR=${ARTIFACT_DIR}

temp_status_dnbc=0
temp_status_bc=0
temp_status_oc=0

export PTP_LOG_LEVEL=debug
export SKIP_INTERFACES=eno8303np0,eno8403np1,eno8503np2,eno8603np3,eno12409,eno8303,ens7f0np0,ens7f1np1,eno8403,ens6f0np0,ens6f1np1,eno8303np0,eno8403np1,eno8503np2,eno8603np3
export PTP_TEST_CONFIG_FILE=${SHARED_DIR}/test-config.yaml

# wait before first run
# wait more to let openshift complete initialization
sleep 300

# get RTC logs
print_time

# Running Dual NIC BC scenario
export PTP_TEST_MODE=dualnicbc
export JUNIT_OUTPUT_FILE=test_results_${PTP_TEST_MODE}.xml
set_events_output_file
make functests || temp_status_dnbc=$?

# wait for old linuxptp-daemon pods to be deleted to avoid remaining ptp GM interference
sleep 60

# get RTC logs
print_time

# Running BC scenario
export PTP_TEST_MODE=bc
export JUNIT_OUTPUT_FILE=test_results_${PTP_TEST_MODE}.xml
set_events_output_file
make functests || temp_status_bc=$?

# wait for old linuxptp-daemon pods to be deleted to avoid remaining ptp GM interference
sleep 60

# get RTC logs
print_time

# Running OC scenario
export PTP_TEST_MODE=oc
export JUNIT_OUTPUT_FILE=test_results_${PTP_TEST_MODE}.xml
set_events_output_file
make functests || temp_status_oc=$?

# get RTC logs
print_time

# saving overall status (all success=0, any failure=1)
status=0
if [[ $temp_status_dnbc != 0 || $temp_status_bc != 0 || $temp_status_oc != 0 ]]; then
  echo  "status for Dual NIC BC scenario = $temp_status_dnbc"
  echo  "status for BC scenario = $temp_status_bc"
  echo  "status for OC scenario = $temp_status_oc"
  status=1
fi

# allows commands to fail without returning
set +e

# clean up, undeploy ptp-operator
make undeploy

# publishing results
cd -

python3 -m venv ${SHARED_DIR}/myenv
source ${SHARED_DIR}/myenv/bin/activate
git clone https://github.com/openshift-kni/telco5gci ${SHARED_DIR}/telco5gci
pip install -r ${SHARED_DIR}/telco5gci/requirements.txt

# Create HTML reports for humans/aliens
python ${SHARED_DIR}/telco5gci/j2html.py ${ARTIFACT_DIR}/test_results_*xml -o ${ARTIFACT_DIR}/test_results_all.html

python ${SHARED_DIR}/telco5gci/j2html.py ${ARTIFACT_DIR}/test_results_dualnicbc.xml -o ${ARTIFACT_DIR}/test_results_dualnicbc.html
python ${SHARED_DIR}/telco5gci/j2html.py ${ARTIFACT_DIR}/test_results_bc.xml -o ${ARTIFACT_DIR}/test_results_bc.html
python ${SHARED_DIR}/telco5gci/j2html.py ${ARTIFACT_DIR}/test_results_oc.xml -o ${ARTIFACT_DIR}/test_results_oc.html

# merge junit files in to one
junitparser merge ${ARTIFACT_DIR}/test_results_*xml ${ARTIFACT_DIR}/test_results_all.xml && \
cp ${ARTIFACT_DIR}/test_results_all.xml ${ARTIFACT_DIR}/junit.xml

# Create JSON reports for robots
python ${SHARED_DIR}/telco5gci/junit2json.py ${ARTIFACT_DIR}/test_results_all.xml -o ${ARTIFACT_DIR}/test_results.json

# delete original separate junit files
#rm -rf ${SHARED_DIR}/myenv ${ARTIFACT_DIR}/test_results_*xml

# delete temp directory
rm -rf $temp_dir

# cancel "allows commands to fail without returning"
set -e

# return saved status
exit ${status}
