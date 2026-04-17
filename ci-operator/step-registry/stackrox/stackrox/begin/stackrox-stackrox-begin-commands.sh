#!/bin/bash

export OPENSHIFT_CI_STEP_NAME="stackrox-stackrox-begin"

echo "INFO: rox-ci-image:"
kubectl get imagestreamtag pipeline:root -o jsonpath='{.tag.from.name}{"\n"}{.image.dockerImageMetadata}' || true
# Query internal registry for image config (labels, env, etc).
_iid=$(kubectl get pod "$HOSTNAME" -o jsonpath='{.status.containerStatuses[?(@.name=="test")].imageID}') || true
echo "INFO: rox-ci-image imageID: ${_iid}"
if [[ "$_iid" =~ ^([^@]+)@(.+)$ ]]; then
    _registry="${BASH_REMATCH[1]%%/*}"
    _repo="${BASH_REMATCH[1]#*/}"
    _digest="${BASH_REMATCH[2]}"
    echo "INFO: rox-ci-image registry=${_registry} repo=${_repo} digest=${_digest}"
    _token=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token) || true
    echo "INFO: rox-ci-image token length: ${#_token}"

    echo "INFO: rox-ci-image: registry v2 catalog test:"
    curl -sk -H "Authorization: Bearer $_token" "https://${_registry}/v2/" || true

    echo "INFO: rox-ci-image: manifest:"
    _manifest=$(curl -sk -H "Authorization: Bearer $_token" \
        -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
        "https://${_registry}/v2/${_repo}/manifests/${_digest}") || true
    echo "$_manifest"

    _config=$(echo "$_manifest" | grep -o '"config":{[^}]*}' | grep -o 'sha256:[a-f0-9]*') || true
    echo "INFO: rox-ci-image: config digest: ${_config}"
    if [[ -n "$_config" ]]; then
        echo "INFO: rox-ci-image: config blob:"
        curl -sk -H "Authorization: Bearer $_token" \
            "https://${_registry}/v2/${_repo}/blobs/${_config}" || true
    fi
else
    echo "INFO: rox-ci-image: imageID did not match expected pattern"
fi
echo "INFO: /i-am-rox-ci-image:"
cat /i-am-rox-ci-image || true

if [[ -f .openshift-ci/begin.sh ]]; then
    exec .openshift-ci/begin.sh
else
    echo "A begin.sh script was not found in the target repo. Which is expected for release branches and migration."
    set -x
    pwd
    ls -l .openshift-ci || true
    set +x
fi
