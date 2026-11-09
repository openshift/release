#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

namespace=keda
deployment=custom-metrics-autoscaler-operator
registry=registry.redhat.io/custom-metrics-autoscaler

csv=$(oc get csv -n "${namespace}" -o name | grep custom-metrics-autoscaler | head -1)
version=$(oc get "${csv}" -n "${namespace}" -o jsonpath='{.spec.version}')

# The previous bundle is built from a release directory in the operator
# repository, but not every one of those directories shipped as a product: 2.18.2
# and 2.18.3 exist only as generated manifests, while 2.18.1 is the newest
# published build of that minor. Their CSVs differ only in version and replaces,
# so the manifests still match the released images. Versions that shipped as-is
# need no entry and fall through unchanged.
case "${version}" in
2.18.*) released=2.18.1 ;;
*)      released="${version}" ;;
esac

operator_image="${registry}/custom-metrics-autoscaler-rhel9-operator:${released}"
keda_image="${registry}/custom-metrics-autoscaler-rhel9:${released}"
adapter_image="${registry}/custom-metrics-autoscaler-adapter-rhel9:${released}"
webhooks_image="${registry}/custom-metrics-autoscaler-admission-webhooks-rhel9:${released}"

echo "Pinning ${csv} (version ${version}) to the released ${released} images"

# ci-operator substitutes the images it builds into every bundle, so without this
# the previous release's manifests would run the operator built from the code
# under test. Point the CSV back at the released images and let OLM reconcile the
# deployment. RELATED_IMAGE_1/2/3 carry the KEDA operator, metrics server and
# admission webhooks operands.
oc get "${csv}" -n "${namespace}" -o json | jq \
  --arg operator "${operator_image}" \
  --arg keda "${keda_image}" \
  --arg adapter "${adapter_image}" \
  --arg webhooks "${webhooks_image}" '
  .metadata.annotations.containerImage = $operator
  | .spec.install.spec.deployments[0].spec.template.spec.containers[0] |= (
      .image = $operator
      | .env |= map(
          if .name == "RELATED_IMAGE_1" then .value = $keda
          elif .name == "RELATED_IMAGE_2" then .value = $adapter
          elif .name == "RELATED_IMAGE_3" then .value = $webhooks
          else . end))' | oc replace -f -

# Update the deployment as well so the rollover starts immediately instead of
# waiting for OLM to notice the CSV changed. Both end up at the same spec, so it
# does not matter which one wins.
oc set image "deployment/${deployment}" -n "${namespace}" "${deployment}=${operator_image}"
oc set env "deployment/${deployment}" -n "${namespace}" \
  "RELATED_IMAGE_1=${keda_image}" \
  "RELATED_IMAGE_2=${adapter_image}" \
  "RELATED_IMAGE_3=${webhooks_image}"

oc wait "deployment/${deployment}" -n "${namespace}" \
  --for=jsonpath="{.spec.template.spec.containers[0].image}=${operator_image}" --timeout=5m
oc rollout status "deployment/${deployment}" -n "${namespace}" --timeout=5m
oc wait "${csv}" -n "${namespace}" --for=jsonpath="{.status.phase}=Succeeded" --timeout=5m
