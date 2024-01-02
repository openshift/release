#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x
cat /etc/os-release
oc config view
oc projects
python --version
pushd /tmp
python -m virtualenv ./venv_qe
source ./venv_qe/bin/activate

ES_PASSWORD=$(cat "/secret/password")
ES_USERNAME=$(cat "/secret/username")


REPO_URL="https://github.com/cloud-bulldozer/e2e-benchmarking";
LATEST_TAG=$(curl -s "https://api.github.com/repos/cloud-bulldozer/e2e-benchmarking/releases/latest" | jq -r '.tag_name');
TAG_OPTION="--branch $(if [ "$E2E_VERSION" == "default" ]; then echo "$LATEST_TAG"; else echo "$E2E_VERSION"; fi)";
git clone $REPO_URL $TAG_OPTION --depth 1
pushd e2e-benchmarking/workloads/kube-burner

export JOB_TIMEOUT=${JOB_TIMEOUT:=21600}

current_worker_count=$(oc get nodes --no-headers -l node-role.kubernetes.io/worker=,node-role.kubernetes.io/infra!=,node-role.kubernetes.io/workload!= --output jsonpath="{.items[?(@.status.conditions[-1].type=='Ready')].status.conditions[-1].type}" | wc -w | xargs)

export WORKLOAD=${WORKLOAD:=networkpolicy-case1}
case $WORKLOAD in
	networkpolicy-case1)
		JOB_ITERATIONS=$(( 5 * $current_worker_count ))
		;;

	networkpolicy-case2)
		JOB_ITERATIONS=$(( 1 * $current_worker_count ))
		;;

	networkpolicy-case3)
		JOB_ITERATIONS=$(( 4 * $current_worker_count ))
		;;
	*)
		echo Unsupported $WORKLOAD workload type
		;;
esac
echo $JOB_ITERATIONS is JOB_ITERATIONS
export JOB_ITERATIONS
export ES_SERVER="https://$ES_USERNAME:$ES_PASSWORD@search-ocp-qe-perf-scale-test-elk-hcm7wtsqpxy7xogbu72bor4uve.us-east-1.es.amazonaws.com"

rm -f ${SHARED_DIR}/index.json

./run.sh

folder_name=$(ls -t -d /tmp/*/ | head -1)
jq ".iterations = $JOB_ITERATIONS" $folder_name/index_data.json >> ${SHARED_DIR}/index_data.json