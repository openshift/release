#!/usr/bin/env bash
set -euo pipefail

export KUBECONFIG=/etc/app-ci-kubeconfig/kubeconfig
registry_config=/etc/push-secret/.dockerconfigjson
workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

jq_art() {
  local filter=$1
  shift
  jq "
    def art_names: [\"stream-coreos\", \"stream-coreos-extensions\"];
    def art_specs: [.spec.tags[]? | select(.name | IN(art_names[]))] | sort_by(.name);
    def has_both_tags: map(.name) == art_names;
    $filter
  " "$@"
}

fail() {
  echo "$1" >&2
  if [[ -s "$workdir/current.json" ]]; then
    jq_art '
      def number: if type == "number" then . else null end;
      def digest: if type == "string" then
        split("@")[-1] | select(test("^sha256:[a-f0-9]{64}$")) else null end;
      {tags: [art_specs[] | {name, generation: (.generation | number),
        digest: (.from.name | digest)}],
       imports: [.status.tags[]? | select(.tag | IN(art_names[])) | {
         tag, generation: (.items[0].generation | number),
         conditions: [.conditions[]? | select(.type == "ImportSuccess") | {
           generation: (.generation | number), success: (.status == "True"),
           reason: (.reason | if IN("RegistryUnavailable", "Unauthorized", "NotFound", "InternalError", "ImportFailed")
             then . else "Other" end)}]}]}
    ' "$workdir/current.json" >&2 || true
  fi
  exit "${2:-1}"
}

validate_inputs() {
  [[ "${JOB_TYPE:?}" == postsubmit ]] || fail 'ART publication is only permitted in postsubmits'
  local file source
  for file in "$KUBECONFIG" "$registry_config"; do
    [[ -f "$file" && -r "$file" && -s "$file" ]] || fail "Required credential file is missing, unreadable or empty: ${file}"
  done
  sources=("${STREAM_COREOS_IMAGE:?}" "${STREAM_COREOS_EXTENSIONS_IMAGE:?}")
  for source in "${sources[@]}"; do
    [[ "$source" =~ ^quay-proxy\.ci\.openshift\.org/openshift/ci@sha256:[a-f0-9]{64}$ ]] ||
      fail 'Expected an immutable build dependency, refusing publication'
  done
}

get_json() {
  oc --request-timeout=10s -n origin get "$1" "$2" -o json > "$3" 2> "$workdir/get.err" ||
    fail 'Unable to read publication inputs; client diagnostics withheld'
}

read_stream() {
  local name=$1 file=$2
  get_json imagestream "$name" "$file"
  jq_art '
    .apiVersion == "image.openshift.io/v1" and .kind == "ImageStream" and
    .metadata.name == $name and .metadata.namespace == "origin" and
    (.metadata.uid | type == "string" and length > 0) and
    (.metadata.resourceVersion | type == "string" and length > 0) and
    (art_specs | has_both_tags)
  ' -e --arg name "$name" "$file" > /dev/null || fail 'Missing or unexpected stream identity or tag cardinality'
}

require_unchanged() {
  cmp -s <(jq_art '[.metadata.uid, art_specs]' -S "$1") <(jq_art '[.metadata.uid, art_specs]' -S "$2") || fail "$3"
}

require_ci_promotion() {
  read_stream scos-5.1 "$workdir/ci-current.json"
  jq_art '
    [art_specs[].from.name] == [$coreos, $extensions] and
    all(art_specs[]; .from.kind == "DockerImage" and .reference == true and
      .referencePolicy.type == "Source" and (.generation | type == "number" and . > 0))
  ' -e --arg coreos "${sources[0]}" --arg extensions "${sources[1]}" "$workdir/ci-current.json" > /dev/null ||
    fail 'Normal CI promotion does not match both originating build digests; refusing ART publication'
  if [[ -f "$workdir/ci-baseline.json" ]]; then
    require_unchanged "$workdir/ci-baseline.json" "$workdir/ci-current.json" 'Normal CI promotion was superseded'
  else
    cp "$workdir/ci-current.json" "$workdir/ci-baseline.json"
  fi
}

mirror_images() {
  require_ci_promotion
  read_stream scos-5.1-art "$workdir/current.json"
  cp "$workdir/current.json" "$workdir/baseline.json"
  local index tag source digest destination
  for index in 0 1; do
    tag=$(jq_art "art_names[${index}]" -nr)
    source=${sources[$index]}
    digest=${source##*@}
    oc image info --registry-config="$registry_config" --show-multiarch --filter-by-os='linux/.*' -o json "$source" > "$workdir/info.json" 2> "$workdir/info.err" ||
      fail 'Unable to verify promoted manifest list; client diagnostics withheld'
    jq --arg digest "$digest" '
      if type == "array" then . else [.] end |
      length > 0 and all(.[]; .listDigest == $digest and .digest == .contentDigest and
        (.digest | type == "string" and test("^sha256:[a-f0-9]{64}$")))
    ' -e "$workdir/info.json" > /dev/null || fail "Promoted source is not the expected manifest list at ${digest}"
    destination="quay.io/openshift/ci:origin_scos-5.1-art_${tag}_${digest#sha256:}"
    oc image mirror --keep-manifest-list=true --registry-config="$registry_config" "$source=$destination" > "$workdir/mirror.out" 2> "$workdir/mirror.err" ||
      fail "ART mirror failed for ${tag} at ${digest}; client diagnostics withheld"
  done
}

require_tag_identity() {
  jq --arg tag "$2" --arg uid "$(jq -r '.metadata.uid' "$workdir/baseline.json")" '
    .apiVersion == "image.openshift.io/v1" and .kind == "ImageStreamTag" and
    .metadata.name == ("scos-5.1-art:" + $tag) and .metadata.namespace == "origin" and
    .metadata.uid == $uid and .tag.name == $tag and
    (.metadata.resourceVersion | type == "string" and length > 0)
  ' -e "$1" > /dev/null || fail 'Missing or unexpected ART tag identity; refusing publication'
}

update_art_tags() {
  local index tag attempt error update_exit expected_conflict conflict_prefix version reason
  for index in 0 1; do
    tag=$(jq_art "art_names[${index}]" -nr)
    for attempt in 1 2 3; do
      require_ci_promotion
      read_stream scos-5.1-art "$workdir/current.json"
      require_unchanged "$workdir/baseline.json" "$workdir/current.json" 'Publication superseded before update; refusing to overwrite'
      get_json imagestreamtag "scos-5.1-art:${tag}" "$workdir/tag.json"
      require_tag_identity "$workdir/tag.json" "$tag"
      cmp -s <(jq --arg tag "$tag" -S '.spec.tags[] | select(.name == $tag)' "$workdir/current.json") <(jq -S '.tag' "$workdir/tag.json") ||
        fail 'Publication superseded before update; refusing to overwrite'
      jq --arg source "${sources[$index]}" --slurpfile stream "$workdir/current.json" '
        {apiVersion, kind, metadata: {name: .metadata.name, namespace: "origin",
           uid: .metadata.uid, resourceVersion: $stream[0].metadata.resourceVersion},
         tag: {name: .tag.name, from: {kind: "DockerImage", name: $source}, reference: false,
           generation: 0, importPolicy: {importMode: "PreserveOriginal"}, referencePolicy: {type: "Source"}}}
      ' "$workdir/tag.json" > "$workdir/update.json"
      if oc --request-timeout=10s -n origin replace -f "$workdir/update.json" -o json > "$workdir/tag-updated.json" 2> "$workdir/replace.err"; then
        require_tag_identity "$workdir/tag-updated.json" "$tag"
        jq --slurpfile desired "$workdir/update.json" '
          .tag as $actual | $desired[0].tag as $expected | $actual |
          .name == $expected.name and .from == $expected.from and
          (.reference // false) == false and .importPolicy.importMode == "PreserveOriginal" and
          .referencePolicy.type == "Source" and (.generation | type == "number" and . > 0)
        ' -e "$workdir/tag-updated.json" > /dev/null || fail 'API response does not match this build, import policy or assigned generation'
        jq --arg tag "$tag" --slurpfile response "$workdir/tag-updated.json" '
          .spec.tags |= map(if .name == $tag then $response[0].tag else . end)
        ' "$workdir/baseline.json" > "$workdir/next.json"
        mv "$workdir/next.json" "$workdir/baseline.json"
        break
      else
        update_exit=$?
      fi
      error=$(cat "$workdir/replace.err")
      expected_conflict="Error from server (Conflict): error when replacing \"${workdir}/update.json\": Operation cannot be fulfilled on imagestreams.image.openshift.io \"scos-5.1-art\": the object has been modified; please apply your changes to the latest version and try again"
      conflict_prefix="Error from server (Conflict): error when replacing \"${workdir}/update.json\": Operation cannot be fulfilled on imagestreamtags.image.openshift.io \"scos-5.1-art:${tag}\": another caller has updated the resource version to "
      version=${error#"$conflict_prefix"}
      if [[ "$error" != "$expected_conflict" ]] && ! { [[ "$version" =~ ^[0-9]+$ ]] && [[ "$error" == "${conflict_prefix}${version}" ]]; }; then
        reason=Unclassified
        case "$error" in
          'Error from server (Forbidden): '*) reason=Forbidden ;;
          'Error from server (Invalid): '*|"The ImageStreamTag \"scos-5.1-art:${tag}\" is invalid: "*) reason=Invalid ;;
        esac
        fail "ART update failed (${reason}; exit ${update_exit}); outcome unconfirmed, not retrying or attributing to another writer" "$update_exit"
      fi
      [[ "$attempt" != 3 ]] || fail 'Unable to update ART imports after three optimistic attempts'
    done
    echo "ART tag ${tag} updated; a subsequent failure can leave a partial publication (no rollback)" >&2
  done
}

wait_for_imports() {
  local attempt
  for ((attempt = 0; attempt < 60; attempt++)); do
    require_ci_promotion
    read_stream scos-5.1-art "$workdir/current.json"
    require_unchanged "$workdir/baseline.json" "$workdir/current.json" 'Publication superseded while waiting for import'
    jq_art '
      . as $stream | any(art_specs[]; . as $spec |
        any($stream.status.tags[]?; .tag == $spec.name and any(.conditions[]?;
          .type == "ImportSuccess" and .status == "False" and .generation == $spec.generation)))
    ' -e "$workdir/current.json" > /dev/null && fail 'ART image import failed'
    if jq_art '
      . as $stream | all(art_specs[]; . as $spec |
        any($stream.status.tags[]?; .tag == $spec.name and
          (.items[0].image // "") != "" and .items[0].image == ($spec.from.name | split("@")[1]) and
          .items[0].generation == $spec.generation))
    ' -e "$workdir/current.json" > /dev/null; then
      require_ci_promotion
      echo 'Both ART CoreOS imports match this build and their current generations'
      return
    fi
    sleep 5
  done
  fail 'Timed out waiting for ART CoreOS imports'
}

validate_inputs
mirror_images
update_art_tags
wait_for_imports
