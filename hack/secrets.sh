#!/bin/bash
# fail if a command fails/undefined variables present
set -eu
kerberos_id=$1
kubeconfig_path=$2
bw_password_path=$3
dry_run=false
run() {
    docker run -it \
        --rm \
        -v "$(pwd)/$BASE/../core-services/prow/02_config:/prow:z" \
        -v "$(pwd)/$BASE/../ci-operator/jobs/:/jobs:z" \
        -v "$kubeconfig_path:/_kubeconfig:z" \
        "$MKPJ_IMG" \
        --config-path /prow/_config.yaml \
        --job-config-path /jobs/ \
        --trigger-job=true \
        --kubeconfig=/_kubeconfig \
        "$@"
}

BASE="$( dirname "${BASH_SOURCE[0]}" )"
source "$BASE/images.sh"

make ci-secret-generator
run --job "periodic-ci-secret-bootstrap"
run --job "periodic-openshift-release-master-core-apply"
run --job "periodic-openshift-release-master-services-apply"
run --job "periodic-openshift-release-master-app-ci-apply"
run --job "periodic-openshift-release-master-build01-apply"
run --job "periodic-openshift-release-master-build02-apply"
run --job "periodic-openshift-release-master-vsphere-apply"
