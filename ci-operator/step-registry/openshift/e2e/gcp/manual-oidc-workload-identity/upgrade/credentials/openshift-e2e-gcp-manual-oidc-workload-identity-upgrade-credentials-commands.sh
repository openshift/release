#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export GCP_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/gce.json"
export GOOGLE_APPLICATION_CREDENTIALS="${GCP_SHARED_CREDENTIALS_FILE}"

infra_name="${NAMESPACE}-${UNIQUE_HASH}"
project="$(< "${CLUSTER_PROFILE_DIR}/openshift_gcp_project")"
region="${LEASED_RESOURCE}"
kubeconfig="${SHARED_DIR}/kubeconfig"
credentials_requests_dir="$(mktemp -d)"
output_dir="$(mktemp -d)"
pull_secret="$(mktemp)"
trap 'rm -rf "${credentials_requests_dir}" "${output_dir}" "${pull_secret}"' EXIT

cp "${CLUSTER_PROFILE_DIR}/pull-secret" "${pull_secret}"
KUBECONFIG="" oc registry login --to "${pull_secret}"

oc adm release extract \
  --registry-config="${pull_secret}" \
  --credentials-requests \
  --cloud=gcp \
  --included \
  --install-config="${SHARED_DIR}/install-config.yaml" \
  --to="${credentials_requests_dir}" \
  "${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE}"

oc get secret bound-service-account-signing-key \
  --namespace openshift-kube-apiserver \
  --output=jsonpath='{.data.service-account\.pub}' \
  | base64 --decode > "${output_dir}/serviceaccount-signer.public"

ccoctl gcp create-all \
  --name="${infra_name}" \
  --region="${region}" \
  --project="${project}" \
  --credentials-requests-dir="${credentials_requests_dir}" \
  --output-dir="${output_dir}" \
  --public-key-file="${output_dir}/serviceaccount-signer.public"

ccoctl gcp apply secrets \
  --output-dir="${output_dir}" \
  --kubeconfig="${kubeconfig}"

target_version="$(oc adm release info \
  --registry-config="${pull_secret}" \
  --output=jsonpath='{.metadata.version}' \
  "${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE}")"

ccoctl gcp set-upgradeable-to "${target_version}" --kubeconfig="${kubeconfig}"
oc wait --for=condition=Upgradeable=True clusteroperator/cloud-credential --timeout=5m
