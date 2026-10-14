#!/usr/bin/env bash
set -euo pipefail

if [[ "${JOB_TYPE:?}" != postsubmit ]]; then
  echo 'ART publication is only permitted in postsubmits' >&2
  exit 1
fi

export KUBECONFIG=/etc/app-ci-kubeconfig/kubeconfig
registry_config=/etc/push-secret/.dockerconfigjson
workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT
tags='["stream-coreos","stream-coreos-extensions"]'

diagnose() {
  echo "$1" >&2
  if [[ -s "$workdir/current.json" ]]; then
    jq --argjson tags "$tags" '{spec: [.spec.tags[]? | select(.name as $name | $tags | index($name))], status: [.status.tags[]? | select(.tag as $name | $tags | index($name))]}' "$workdir/current.json" >&2
  fi
}

get_stream() {
  oc --request-timeout=10s -n origin get imagestream scos-5.1-art -o json > "$workdir/current.json"
}

target_spec() {
  jq -S --argjson tags "$tags" '[.spec.tags[]? | select(.name as $name | $tags | index($name))] | sort_by(.name)' "$1"
}

sources=("${STREAM_COREOS_IMAGE:?}" "${STREAM_COREOS_EXTENSIONS_IMAGE:?}")
for source in "${sources[@]}"; do
  if [[ ! "$source" =~ ^[^[:space:]@]+@sha256:[a-f0-9]{64}$ ]]; then
    echo 'Expected an immutable build dependency, refusing publication' >&2
    exit 1
  fi
done

get_stream
cp "$workdir/current.json" "$workdir/baseline.json"
target_spec "$workdir/baseline.json" > "$workdir/baseline-tags.json"
printf '[]' > "$workdir/desired.json"
for index in 0 1; do
  tag=$(jq -r ".[${index}]" <<< "$tags")
  source=${sources[$index]}
  digest=${source##*@}
  destination="quay.io/openshift/ci:origin_scos-5.1-art_${tag}_${digest#sha256:}"
  oc image mirror --keep-manifest-list=true --registry-config="$registry_config" "$source=$destination"
  jq --arg name "$tag" --arg source "quay-proxy.ci.openshift.org/openshift/ci@${digest}" \
    '. + [{name: $name, from: {kind: "DockerImage", name: $source}, reference: false, generation: 0, importPolicy: {importMode: "PreserveOriginal"}, referencePolicy: {type: "Source"}}]' \
    "$workdir/desired.json" > "$workdir/next.json"
  mv "$workdir/next.json" "$workdir/desired.json"
done

updated=false
for attempt in 1 2 3; do
  if ! cmp -s "$workdir/baseline-tags.json" <(target_spec "$workdir/current.json") ||
    [[ $(jq -r '.metadata.uid' "$workdir/current.json") != $(jq -r '.metadata.uid' "$workdir/baseline.json") ]]; then
    diagnose 'Publication superseded before update; refusing to overwrite'
    exit 1
  fi
  jq --slurpfile desired "$workdir/desired.json" --argjson tags "$tags" \
    '.spec.tags = ([.spec.tags[]? | select(.name as $name | $tags | index($name) | not)] + $desired[0])' \
    "$workdir/current.json" > "$workdir/update.json"
  if oc --request-timeout=10s -n origin replace -f "$workdir/update.json" -o json > "$workdir/updated.json"; then
    updated=true
    break
  fi
  get_stream
done
if [[ "$updated" != true ]]; then
  diagnose 'Unable to update ART imports after three optimistic attempts'
  exit 1
fi
target_spec "$workdir/updated.json" > "$workdir/updated-tags.json"
if ! jq -e --slurpfile desired "$workdir/desired.json" '. as $stream | all($desired[0][]; . as $expected | any($stream.spec.tags[]?; .name == $expected.name and .from == $expected.from and (.reference // false) == false and .importPolicy.importMode == "PreserveOriginal" and .referencePolicy.type == "Source"))' "$workdir/updated.json" > /dev/null; then
  cp "$workdir/updated.json" "$workdir/current.json"
  diagnose 'ART update response does not match this build or its import policy'
  exit 1
fi
if ! jq -e --argjson tags "$tags" '[.spec.tags[]? | select(.name as $name | $tags | index($name))] | length == 2 and all(.[]; .generation > 0)' "$workdir/updated.json" > /dev/null; then
  diagnose 'API did not assign import generations'
  exit 1
fi

for ((attempt = 0; attempt < 60; attempt++)); do
  get_stream
  if ! cmp -s "$workdir/updated-tags.json" <(target_spec "$workdir/current.json") ||
    [[ $(jq -r '.metadata.uid' "$workdir/current.json") != $(jq -r '.metadata.uid' "$workdir/updated.json") ]]; then
    diagnose 'Publication superseded while waiting for import'
    exit 1
  fi
  if jq -e --argjson tags "$tags" '. as $stream | any(.spec.tags[]?; . as $spec | ($tags | index($spec.name)) != null and any($stream.status.tags[]?; .tag == $spec.name and any(.conditions[]?; .type == "ImportSuccess" and .status == "False" and .generation == $spec.generation)))' "$workdir/current.json" > /dev/null; then
    diagnose 'ART image import failed'
    exit 1
  fi
  if jq -e --argjson tags "$tags" '. as $stream | [.spec.tags[]? | select(.name as $name | $tags | index($name))] | all(.[]; . as $spec | any($stream.status.tags[]?; .tag == $spec.name and (.items[0].image // "") != "" and .items[0].image == ($spec.from.name | split("@")[1]) and .items[0].generation == $spec.generation))' "$workdir/current.json" > /dev/null; then
    echo 'Both ART CoreOS imports match this build and their current generations'
    exit 0
  fi
  sleep 5
done
diagnose 'Timed out waiting for ART CoreOS imports'
exit 1
