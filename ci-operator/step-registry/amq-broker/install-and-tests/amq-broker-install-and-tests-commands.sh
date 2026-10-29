#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Create config file"
mkdir /app/.kube
touch /app/.kube/config

echo "EXPORT KUBECONFIG to /app/.kube/config"
cp $KUBECONFIG /app/.kube/config
export KUBECONFIG=/app/.kube/config

echo "Execute tests"
operator-suite/container/scripts/run-test.sh --make-envvar OLM=true --image-tag $TEST_IMAGE_TAG || true

echo "Renaming xmls to junit_*.xml"
result_dir="/app/test-results/operator-suite"
readarray -t files <<< "$(find ${result_dir} -name 'TEST-*.xml')"
for file in "${files[@]}"; do
jfile="$(echo "${file}" | awk -F/ '{print $(NF)}')"; mv "${file}" "${result_dir}/junit_${jfile}";
done

echo "Copy logs and xmls to ARTIFACT_DIR"
cp -r ${result_dir} $ARTIFACT_DIR
