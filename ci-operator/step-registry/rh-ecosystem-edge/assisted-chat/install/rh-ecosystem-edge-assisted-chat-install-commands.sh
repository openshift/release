#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

#$ASSISTED_CHAT_IMG is not in repo/image:tag format but rather in repo/<image name>@sha256:<digest>
#The template needs the tag, and it references the image by <image name>:<tag> so splitting the variable by ":" works for now

echo $ASSISTED_CHAT_IMG
IMAGE=$(echo $ASSISTED_CHAT_IMG | cut -d ":" -f1)
TAG=$(echo $ASSISTED_CHAT_IMG | cut -d ":" -f2)

oc create namespace $NAMESPACE || true
oc create secret generic -n $NAMESPACE gemini-api-key --from-file=api_key=/var/run/secrets/gemini/api_key
oc create secret generic -n $NAMESPACE llama-stack-db --from-file=db.ca_cert=/var/run/secrets/llama-stack-db/db.ca_cert \
                                                      --from-file=db.host=/var/run/secrets/llama-stack-db/db.host \
                                                      --from-file=db.name=/var/run/secrets/llama-stack-db/db.name \
                                                      --from-file=db.password=/var/run/secrets/llama-stack-db/db.password \
                                                      --from-file=db.port=/var/run/secrets/llama-stack-db/db.port \
                                                      --from-file=db.user=/var/run/secrets/llama-stack-db/db.user

patch template.yaml -i test/prow/template_patch.diff
echo "GEMINI_API_KEY=$(cat /var/run/secrets/gemini/api_key)" > .env
make generate
sed -i 's/user_id_claim: sub/user_id_claim: client_id/g' config/lightspeed-stack.yaml
sed -i 's/username_claim: preferred_username/username_claim: clientHost/g' config/lightspeed-stack.yaml

oc process -p IMAGE=$IMAGE -p IMAGE_TAG=$TAG -p GEMINI_API_SECRET_NAME=gemini-api-key -p ASSISTED_CHAT_DB_SECRET_NAME=llama-stack-db -f template.yaml --local > template.json
cat template.json | jq 'del(.items[] | select(.kind == "Route"))' > template_without_route.json
cp template.json ${ARTIFACT_DIR}/template.json
cp template_without_route.json ${ARTIFACT_DIR}/template_without_route.json

if oc api-resources -n $NAMESPACE | grep route.openshift.io; then
    echo "the resource 'Route' found in 'route.openshift.io'"
    oc apply -n $NAMESPACE -f template.json
else
    echo "the resource 'Route' was not found"
    oc apply -n $NAMESPACE -f template_without_route.json
fi

sleep 5
POD_NAME=$(oc get pods | tr -s ' ' | cut -d ' ' -f1| grep assisted-chat)
oc wait --for=condition=Ready pod/$POD_NAME --timeout=300s
