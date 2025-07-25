#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

#$ASSISTED_CHAT_IMG is not in repo/image:tag format but rather in repo/<image name>@sha256:<digest>
#The template needs the tag, and it references the image by <image name>:<tag> so splitting the variable by ":" works for now

echo $ASSISTED_CHAT_IMG
IMAGE=$(echo $ASSISTED_CHAT_IMG | cut -d ":" -f1)
TAG=$(echo $ASSISTED_CHAT_IMG | cut -d ":" -f2)

echo "checking the gemini secret"
ls -l /var/run/secrets/gemini
cat /var/run/secrets/gemini/* || true
echo  "secret end"
oc process -p IMAGE=$IMAGE -p IMAGE_TAG=$TAG -p ROUTE_HOST=local-assisted-chat.com -f template.yaml --local > template.json
cat template.json | jq 'del(.items[] | select(.kind == "Route"))' > template_without_route.json
cat template.json
echo "the current namespace is: $NAMESPACE"
oc project
oc create namespace $NAMESPACE || true
oc apply -f template.json
echo "THE ENVIRONMENTAL VARIALBLES"
printenv
echo "THESE WERE THE ENVIRONMENTAL VARIABLES"
echo "oc get pods"
oc get pods
echo "oc get route"
oc get route
echo "oc get service"
oc get service
echo "oc get deploy"
oc get deploy
echo "KUBECONFIG='' oc get pods"
KUBECONFIG='' oc get pods
echo "podman ps -a"
podman ps -a || true