#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
# Do not enable `set -x`: these scripts read and export Elasticsearch
# credentials (ES_USERNAME/ES_PASSWORD) and construct an authenticated
# ES_SERVER URL; tracing would leak them into the CI logs.

# Self-managed HyperShift. Both files are written by the hypershift-etcd-perf
# chain and absent everywhere else, so this is a no-op on a standalone cluster.
#
# A hosted cluster is split across two clusters: the workload is applied to the
# guest API server, but the etcd and kube-apiserver being measured are pods on
# the management cluster. So the load goes to nested_kubeconfig while the
# metrics come from the endpoint file hypershift-hcp-metrics-endpoint prepared.
HCP_METRICS_ENDPOINT="${SHARED_DIR}/hcp-metrics-endpoint.yml"
HOSTED_CLUSTER=false
if [[ -s "${SHARED_DIR}/nested_kubeconfig" && -s "${HCP_METRICS_ENDPOINT}" ]]; then
    HOSTED_CLUSTER=true
    echo "Hosted cluster detected; driving the workload against the guest API server"
    export KUBECONFIG="${SHARED_DIR}/nested_kubeconfig"
    # The hosted control plane profile scopes every query to this namespace and
    # breaks the series down by pod, which is what separates one etcd shard
    # from another. kube-burner renders the profiles over the environment.
    HOSTED_CLUSTER_NAMESPACE="$(cat "${SHARED_DIR}/hcp-namespace")"
    export HOSTED_CLUSTER_NAMESPACE
    # run.sh only reaches for MC_KUBECONFIG on the ROSA and ARO paths, which
    # derive the control plane namespace in ways that do not hold here. Make
    # sure an inherited value cannot send it down one of them.
    unset MC_KUBECONFIG
fi

oc projects
oc version
pushd /tmp

ES_SECRETS_PATH=${ES_SECRETS_PATH:-/secret}
ES_HOST="search-ocp-qe-perf-scale-test-elk-hcm7wtsqpxy7xogbu72bor4uve.us-east-1.es.amazonaws.com"
ES_PASSWORD=$(cat "${ES_SECRETS_PATH}/password")
ES_USERNAME=$(cat "${ES_SECRETS_PATH}/username")
if [ -e "${ES_SECRETS_PATH}/host" ]; then
    ES_HOST=$(cat "${ES_SECRETS_PATH}/host")
fi
UUID=$(uuidgen)

REPO_URL="https://github.com/cloud-bulldozer/e2e-benchmarking"
LATEST_TAG=$(git ls-remote --tags "${REPO_URL}.git" | awk -F'refs/tags/' '{print $2}' | grep -v '\^{}' | sort -V | tail -n1)
TAG_OPTION="--branch $(if [ "$E2E_VERSION" == "default" ]; then echo "$LATEST_TAG"; else echo "$E2E_VERSION"; fi)"
git clone $REPO_URL $TAG_OPTION --depth 1
pushd e2e-benchmarking/workloads/kube-burner-ocp-wrapper

export WORKLOAD="etcd-density annotation-churn"
# Patch the indexing call in run.sh so the fingerprint records "annotation-churn"
sed -i '/index\.sh/s|WORKLOAD="$WORKLOAD"|WORKLOAD="annotation-churn"|' run.sh

if [[ "${HOSTED_CLUSTER}" == "true" ]]; then
    # kube-burner-ocp declares --es-server and --metrics-endpoint mutually
    # exclusive, and the hosted control plane series only exist on the
    # endpoint, so run.sh must not add --es-server. It adds it whenever
    # ES_SERVER is set, and ES_SERVER has to stay set: the endpoint file
    # resolves {{.ES_SERVER}} from the environment to index to Elasticsearch,
    # and index.sh needs it for the CI fingerprint. So drop the one line
    # rather than the variable.
    #
    # The real fix is a self-managed HyperShift branch in run.sh next to its
    # ROSA and ARO ones, which is e2e-benchmarking's to make.
    if ! grep -q 'cmd+=" --es-server=' run.sh; then
        echo "FATAL: run.sh no longer builds the --es-server flag the way this step expects."
        echo "Re-check the ES_SERVER handling in kube-burner-ocp-wrapper/run.sh."
        exit 1
    fi
    # Replaced by a no-op rather than deleted: the line is the whole body of an
    # elif branch, and an empty branch is a syntax error.
    sed -i 's@^.*cmd+=" --es-server=.*$@  :@' run.sh
    bash -n run.sh
fi

# Variant-specific flags
EXTRA_FLAGS="--iterations=${ANNOTATION_CHURN_ITERATIONS} --patch-replicas=${PATCH_REPLICAS} --patch-rounds=${PATCH_ROUNDS}"
# Flags not handled by run.sh
EXTRA_FLAGS+=" --gc-metrics=${GC_METRICS} --profile-type=${PROFILE_TYPE}"
if [[ "${HOSTED_CLUSTER}" == "true" ]]; then
    # The endpoint file names its own profiles, so --metrics-profile does not apply.
    EXTRA_FLAGS+=" --metrics-endpoint=${HCP_METRICS_ENDPOINT}"
else
    EXTRA_FLAGS+=" --metrics-profile=${METRICS_PROFILES}"
fi
if [[ "${ENABLE_LOCAL_INDEX}" == "true" ]]; then
    EXTRA_FLAGS+=" --local-indexing"
fi
if [[ -n "${USER_METADATA}" ]]; then
    echo "${USER_METADATA}" > user-metadata.yaml
    EXTRA_FLAGS+=" --user-metadata=user-metadata.yaml"
fi
EXTRA_FLAGS+=" ${KB_FLAGS}"

export ES_SERVER="https://$ES_USERNAME:$ES_PASSWORD@$ES_HOST"
if [[ "${HOSTED_CLUSTER}" == "true" ]]; then
    # The endpoint file's Elasticsearch indexer is written as {{.ES_SERVER}}
    # and {{.ES_INDEX}}; kube-burner renders the file over the environment
    # before parsing it. ES_INDEX is a local in run.sh, so export it here or
    # the render fails on the missing key.
    export ES_INDEX="${ES_INDEX:-ripsaw-kube-burner}"
fi
export EXTRA_FLAGS UUID ADDITIONAL_PARAMS

set +o errexit
./run.sh
RUN_EXIT_CODE=$?
set -o errexit

METRICS_FOLDER="collected-metrics-${UUID}"
if [[ -d ${METRICS_FOLDER} ]]; then
    cp -r ${METRICS_FOLDER} "${ARTIFACT_DIR}/"
fi

exit ${RUN_EXIT_CODE}
