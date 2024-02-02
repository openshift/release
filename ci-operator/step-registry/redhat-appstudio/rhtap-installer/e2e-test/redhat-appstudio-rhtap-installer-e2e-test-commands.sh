#!/usr/bin/env bash
set -o errexit
set -o nounset
set -o pipefail

DEBUG_OUTPUT=/tmp/log.txt
export ACS_API_TOKEN ACS_CENTRAL_ENDPOINT DEVELOPER_HUB_CATALOG_URL GITHUB_APP_ID GITHUB_APP_CLIENT_ID GITHUB_APP_CLIENT_SECRET GITHUB_APP_WEBHOOK_SECRET GITHUB_APP_WEBHOOK_URL GITHUB_APP_PRIVATE_KEY
ACS_API_TOKEN=$(cat /usr/local/ci-secrets/rhtap/acs-api-token)
ACS_CENTRAL_ENDPOINT=$(cat /usr/local/ci-secrets/rhtap/acs-central-endpoint)
DEVELOPER_HUB_CATALOG_URL=https://github.com/redhat-appstudio/tssc-sample-templates/blob/main/all.yaml
GITHUB_APP_ID=$(cat /usr/local/ci-secrets/rhtap/rhdh-github-app-id)
GITHUB_APP_CLIENT_ID=$(cat /usr/local/ci-secrets/rhtap/rhdh-github-client-id)
GITHUB_APP_CLIENT_SECRET=$(cat /usr/local/ci-secrets/rhtap/rhdh-github-client-secret)
GITHUB_APP_WEBHOOK_SECRET=$(cat /usr/local/ci-secrets/rhtap/rhdh-github-webhook-secret)
GITHUB_APP_WEBHOOK_URL=GITHUB_APP_WEBHOOK_URL
GITHUB_APP_PRIVATE_KEY=$(base64 -d < /usr/local/ci-secrets/rhtap/rhdh-github-private-key)

wait_for_pipeline() {
  if ! kubectl wait --for=condition=succeeded "$1" -n "$2" --timeout 300s >"$DEBUG_OUTPUT"; then
    echo "[ERROR] Pipeline failed to complete successful" >&2
    kubectl get pipelineruns "$1" -n "$2" >"$DEBUG_OUTPUT"
    exit 1
  fi
}

echo "Generate private-values.yaml file ..."
./bin/make.sh values

echo "Install RHTAP ..."
./bin/make.sh apply -- --values private-values.yaml

echo ""
echo "Extract the configuration information from logs of the pipeline"

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

pipeline_name=$(kubectl create -f rhtap-pe-info.yaml | cut -d' ' -f1 | awk -F'/' '{print $2}')
wait_for_pipeline "pipelineruns/$pipeline_name" rhtap
tkn -n rhtap pipelinerun logs "$$pipeline_name" -f >"$DEBUG_OUTPUT"

homepage_url=$(grep "homepage-url" < "$DEBUG_OUTPUT" | sed 's/.*: //g')
callback_url=$(grep "callback-url" < "$DEBUG_OUTPUT" | sed 's/.*: //g')
webhook_url=$(grep "webhook-url" < "$DEBUG_OUTPUT"  | sed 's/.*: //g') 

echo "homepage-url: $homepage_url"
echo "callback-url: $callback_url"
echo "webhook-url: $webhook_url"

##todo: handle the requests via sprayproxy
echo "Trigger e2e tests"
./test/e2e.sh -t test -- --values private-values.yaml
