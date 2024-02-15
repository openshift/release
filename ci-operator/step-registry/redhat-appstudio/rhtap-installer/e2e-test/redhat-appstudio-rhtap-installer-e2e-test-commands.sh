#!/usr/bin/env bash
set -o errexit
set -o nounset
set -o pipefail

DEBUG_OUTPUT=/tmp/log.txt

wait_for_pipeline() {
  if ! oc wait --for=condition=succeeded "$1" -n "$2" --timeout 300s >"$DEBUG_OUTPUT"; then
    echo "[ERROR] Pipeline failed to complete successful" >&2
    oc get pipelineruns "$1" -n "$2" >"$DEBUG_OUTPUT"
    exit 1
  fi
}

echo ""
echo "[INFO]Extract the configuration information from logs of the pipeline"

cat << EOF > rhtap-pe-info.yaml
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  generateName: rhtap-pe-info-
  namespace: rhtap
spec:
  pipelineSpec:
    tasks:
      - name: configuration-info
        taskRef:
          resolver: cluster
          params:
            - name: kind
              value: task
            - name: name
              value: rhtap-pe-info
            - name: namespace
              value: rhtap
EOF

pipeline_name=$(oc create -f rhtap-pe-info.yaml | cut -d' ' -f1 | awk -F'/' '{print $2}')
wait_for_pipeline "pipelineruns/$pipeline_name" rhtap
tkn -n rhtap pipelinerun logs "$$pipeline_name" -f >"$DEBUG_OUTPUT"

homepage_url=$(grep "homepage-url" < "$DEBUG_OUTPUT" | sed 's/.*: //g')
callback_url=$(grep "callback-url" < "$DEBUG_OUTPUT" | sed 's/.*: //g')
webhook_url=$(grep "webhook-url" < "$DEBUG_OUTPUT"  | sed 's/.*: //g') 

echo "homepage-url: $homepage_url"
echo "callback-url: $callback_url"
echo "webhook-url: $webhook_url"

##todo: handle the requests via sprayproxy
echo "[INFO]Trigger e2e tests..."
# ./test/e2e.sh -t test -- --values private-values.yaml
./bin/make.sh -n rhtap test
