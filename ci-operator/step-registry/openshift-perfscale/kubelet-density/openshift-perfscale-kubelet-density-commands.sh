#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x 

export QPS=20
export BURST=20
export ES_SERVER=https://search-cloud-perf-lqrf3jjtaqo7727m7ynd2xyt4y.us-west-2.es.amazonaws.com
export ES_PORT=443
export ES_INDEX=ripsaw-kube-burner
export PROM_URL=https://prometheus-k8s.openshift-monitoring.svc.cluster.local:9091
export JOB_TIMEOUT=1800
export WORKLOAD_NODE=""
export CERBERUS_URL=""
export STEP_SIZE=30s
export CLEANUP=false
export CLEANUP_WHEN_FINISH=false
export LOG_LEVEL=info

# Kubelet-density and kubelet-density-heavy specific
export NODE_COUNT=3
export PODS_PER_NODE=50

# Metadata
export METADATA_COLLECTION=true

# kube-burner log streaming
export LOG_STREAMING=true
export CLEANUP_WHEN_FINISH=true

pushd /tmp
curl -sS https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/openshift-client-linux.tar.gz | tar xz
export PATH=${PATH}:/tmp

#git clone https://github.com/cloud-bulldozer/e2e-benchmarking.git --depth=1
token=$(oc sa get-token -n openshift-monitoring prometheus-k8s)
prometheus_url=https://$(oc get route -n openshift-monitoring prometheus-k8s -o yaml -o jsonpath="{.spec.host}")

warmup=https://raw.githubusercontent.com/rsevilla87/cluster-perf-ci/master/warm-up.yml
load_cluster=https://raw.githubusercontent.com/rsevilla87/cluster-perf-ci/master/load-cluster.yml
git clone https://github.com/cloud-bulldozer/kube-burner.git --depth=1
pushd kube-burner
make build -j $(nproc)
# Warm-up
./bin/kube-burner init -c ${warmup} -u ${prometheus_url} -t ${token} -a https://raw.githubusercontent.com/rsevilla87/cluster-perf-ci/master/alert-profiles/generalistic.yml --uuid $(uuidgen)

# Load-cluster
./bin/kube-burner init -c ${load_cluster} -u ${prometheus_url} -t ${token} -a https://raw.githubusercontent.com/rsevilla87/cluster-perf-ci/master/alert-profiles/generalistic.yml --uuid $(uuidgen) -m https://raw.githubusercontent.com/rsevilla87/cluster-perf-ci/master/metric-profiles/metrics.yml 2>&1 | tee -a kube-burner.log
cp kube-burner-job.log ${ARTIFACT_DIR}/kube-burner-job.log
