#!/usr/bin/env bash
set -euo pipefail

export KUBECONFIG=/etc/app-ci-kubeconfig/kubeconfig
registry_config=/etc/push-secret/.dockerconfigjson

validate_inputs() {
  if [[ "${JOB_TYPE:?}" != postsubmit ]]; then
    echo 'ART publication is only permitted in postsubmits' >&2
    exit 1
  fi
  local credential_file source
  for credential_file in "$KUBECONFIG" "$registry_config"; do
    if [[ ! -f "$credential_file" || ! -r "$credential_file" || ! -s "$credential_file" ]]; then
      echo "Required credential file is missing, unreadable or empty: ${credential_file}" >&2
      exit 1
    fi
  done
  sources=("${STREAM_COREOS_IMAGE:?}" "${STREAM_COREOS_EXTENSIONS_IMAGE:?}")
  for source in "${sources[@]}"; do
    if [[ ! "$source" =~ ^quay-proxy\.ci\.openshift\.org/openshift/ci@sha256:[a-f0-9]{64}$ ]]; then
      echo 'Expected an immutable build dependency, refusing publication' >&2
      exit 1
    fi
  done
}

require_ci_promotion() {
  if ! oc --request-timeout=10s -n origin get imagestream scos-5.1 -o json > "$workdir/ci-current.json" 2> "$workdir/get.err"; then
    echo 'Unable to verify normal CI promotion; client diagnostics withheld' >&2
    exit 1
  fi
  if ! jq_art '
    .apiVersion == "image.openshift.io/v1" and .kind == "ImageStream" and
    .metadata.name == "scos-5.1" and .metadata.namespace == "origin" and
    (.metadata.uid | type == "string" and length > 0) and
    (art_specs | has_both_tags) and
    ([art_specs[].from.name] == [$coreos, $extensions]) and
    all(art_specs[];
      .from.kind == "DockerImage" and .reference == true and
      .referencePolicy.type == "Source" and
      (.generation | type == "number" and . > 0))
  ' -e --arg coreos "${sources[0]}" --arg extensions "${sources[1]}" "$workdir/ci-current.json" > /dev/null; then
    echo 'Normal CI promotion does not match both originating build digests; refusing ART publication' >&2
    exit 1
  fi
  if [[ -f "$workdir/ci-baseline.json" ]]; then
    if ! cmp -s <(jq_art '[.metadata.uid, art_specs]' -S "$workdir/ci-baseline.json") <(jq_art '[.metadata.uid, art_specs]' -S "$workdir/ci-current.json"); then
      echo 'Normal CI promotion was superseded; refusing ART publication success' >&2
      exit 1
    fi
  else
    cp "$workdir/ci-current.json" "$workdir/ci-baseline.json"
  fi
}

require_manifest_list() {
  local source=$1 digest
  digest=${source##*@}
  if ! oc image info --registry-config="$registry_config" --show-multiarch --filter-by-os='linux/.*' -o json "$source" > "$workdir/image-info.out" 2> "$workdir/image-info.err"; then
    echo 'Unable to verify promoted manifest list; client diagnostics withheld' >&2
    exit 1
  fi
  if ! jq --arg digest "$digest" '
    if type == "array" then . else [.] end |
    length > 0 and all(.[]; .listDigest == $digest and
      (.digest | type == "string" and test("^sha256:[a-f0-9]{64}$")) and
      .digest == .contentDigest)
  ' -e "$workdir/image-info.out" > /dev/null; then
    echo "Promoted source is not the expected manifest list at ${digest}" >&2
    exit 1
  fi
}

jq_art() {
  local filter=$1
  shift
  jq "
    def art_names: [\"stream-coreos\", \"stream-coreos-extensions\"];
    def is_art_tag: IN(art_names[]);
    def art_specs:
      [.spec.tags[]? | select(.name | is_art_tag)] | sort_by(.name);
    def has_both_tags:
      (map(.name) | sort) == (art_names | sort);
    $filter
  " "$@"
}

diagnose() {
  echo "$1" >&2
  if [[ -s "$workdir/current.json" ]]; then
    jq_art '
      def digest:
        if type == "string" then
          split("@")[-1] | if test("^sha256:[a-f0-9]{64}$") then . else null end
        else null end;
      def generation: if type == "number" then . else null end;
      def reason:
        if IN("RegistryUnavailable", "Unauthorized", "NotFound", "InternalError", "ImportFailed")
        then . else "Other" end;
      {
        spec: [art_specs[] | {
          name, digest: (.from.name | digest), generation: (.generation | generation)
        }],
        status: [.status.tags[]? | select(.tag | is_art_tag) | {
          tag,
          latest: [.items[:1][]? | {
            digest: (.image | digest), generation: (.generation | generation)
          }],
          conditions: [.conditions[]? | select(.type == "ImportSuccess") | {
            generation: (.generation | generation),
            success: (.status == "True"), reason: (.reason | reason)
          }]
        }]
      }
    ' "$workdir/current.json" >&2
  fi
}

get_stream() {
  if ! oc --request-timeout=10s -n origin get imagestream scos-5.1-art -o json > "$workdir/current.json" 2> "$workdir/get.err"; then
    echo 'Unable to read ART ImageStream; client diagnostics withheld to avoid exposing credentials' >&2
    exit 1
  fi
  if ! jq_art '
    .apiVersion == "image.openshift.io/v1" and .kind == "ImageStream" and
    .metadata.name == "scos-5.1-art" and .metadata.namespace == "origin" and
    (.metadata.uid | type == "string" and length > 0) and
    (.metadata.resourceVersion | type == "string" and length > 0) and
    (art_specs | has_both_tags)
  ' -e "$workdir/current.json" > /dev/null; then
    echo 'Missing or unexpected ART stream identity or tag cardinality' >&2
    exit 1
  fi
}

require_tag_identity() {
  local file=$1 tag=$2
  case "$tag" in stream-coreos|stream-coreos-extensions) ;; *) exit 1 ;; esac
  if ! jq --arg tag "$tag" --arg uid "$(jq -r '.metadata.uid' "$workdir/baseline.json")" '
    .apiVersion == "image.openshift.io/v1" and .kind == "ImageStreamTag" and
    .metadata.name == ("scos-5.1-art:" + $tag) and .metadata.namespace == "origin" and
    .metadata.uid == $uid and
    (.metadata.resourceVersion | type == "string" and length > 0) and .tag.name == $tag
  ' -e "$file" > /dev/null; then
    echo 'Missing or unexpected ART tag identity; refusing publication' >&2
    exit 1
  fi
}

require_unchanged() {
  local previous=$1 message=$2
  if ! cmp -s <(jq_art 'art_specs' -S "$previous") <(jq_art 'art_specs' -S "$workdir/current.json") ||
    [[ $(jq -r '.metadata.uid' "$previous") != $(jq -r '.metadata.uid' "$workdir/current.json") ]]; then
    diagnose "$message"
    exit 1
  fi
}

mirror_images() {
  require_ci_promotion
  local source
  for source in "${sources[@]}"; do
    require_manifest_list "$source"
  done
  get_stream
  cp "$workdir/current.json" "$workdir/baseline.json"
  printf '[]' > "$workdir/desired.json"
  local index tag digest destination
  for index in 0 1; do
    tag=$(jq_art "art_names[${index}]" -nr)
    source=${sources[$index]}
    digest=${source##*@}
    destination="quay.io/openshift/ci:origin_scos-5.1-art_${tag}_${digest#sha256:}"
    if ! oc image mirror --keep-manifest-list=true --registry-config="$registry_config" "$source=$destination" > "$workdir/mirror.out" 2> "$workdir/mirror.err"; then
      echo "ART mirror failed for ${tag} at ${digest}; client diagnostics withheld to avoid exposing credentials" >&2
      exit 1
    fi
    jq --arg name "$tag" --arg source "quay-proxy.ci.openshift.org/openshift/ci@${digest}" '
      . + [{
        name: $name,
        from: {kind: "DockerImage", name: $source},
        reference: false,
        generation: 0,
        importPolicy: {importMode: "PreserveOriginal"},
        referencePolicy: {type: "Source"}
      }]
    ' "$workdir/desired.json" > "$workdir/next.json"
    mv "$workdir/next.json" "$workdir/desired.json"
  done
}

verify_update_response() {
  local tag=$1
  require_tag_identity "$workdir/tag-updated.json" "$tag"
  if ! jq '
    .tag as $actual | $desired[0].tag as $expected | $actual |
      .name == $expected.name and .from == $expected.from and
      (.reference // false) == false and
      .importPolicy.importMode == "PreserveOriginal" and
      .referencePolicy.type == "Source"
  ' -e --slurpfile desired "$workdir/update.json" "$workdir/tag-updated.json" > /dev/null; then
    diagnose 'ART update response does not match this build or its import policy'
    exit 1
  fi
  if ! jq '.tag.generation | type == "number" and . > 0' -e "$workdir/tag-updated.json" > /dev/null; then
    diagnose 'API did not assign import generations'
    exit 1
  fi
}

update_art_tags() {
  local tag
  for tag in stream-coreos stream-coreos-extensions; do
    if [[ "$tag" == stream-coreos-extensions ]]; then
      echo 'First ART tag updated; a subsequent failure can leave a partial publication (no rollback)' >&2
    fi
    update_art_tag "$tag"
  done
  cp "$workdir/baseline.json" "$workdir/updated.json"
}

update_art_tag() {
  local tag=$1 attempt update_exit error expected_conflict reason conflict_prefix version
  for attempt in 1 2 3; do
    require_ci_promotion
    get_stream
    require_unchanged "$workdir/baseline.json" 'Publication superseded before update; refusing to overwrite'
    if ! oc --request-timeout=10s -n origin get imagestreamtag "scos-5.1-art:${tag}" -o json > "$workdir/tag.json" 2> "$workdir/get.err"; then
      echo 'Unable to read existing ART tag; client diagnostics withheld' >&2
      exit 1
    fi
    require_tag_identity "$workdir/tag.json" "$tag"
    if ! cmp -s <(jq --arg tag "$tag" -S '.spec.tags[] | select(.name == $tag)' "$workdir/baseline.json") <(jq -S '.tag' "$workdir/tag.json"); then
      diagnose 'Publication superseded before update; refusing to overwrite'
      exit 1
    fi
    jq --arg tag "$tag" --arg version "$(jq -r '.metadata.resourceVersion' "$workdir/current.json")" --slurpfile desired "$workdir/desired.json" '
      {apiVersion: "image.openshift.io/v1", kind: "ImageStreamTag",
       metadata: {name: ("scos-5.1-art:" + $tag), namespace: "origin",
         uid: .metadata.uid, resourceVersion: $version},
       tag: ($desired[0][] | select(.name == $tag))}
    ' "$workdir/tag.json" > "$workdir/update.json"
    if oc --request-timeout=10s -n origin replace -f "$workdir/update.json" -o json > "$workdir/tag-updated.json" 2> "$workdir/replace.err"; then
      verify_update_response "$tag"
      jq --arg tag "$tag" --slurpfile response "$workdir/tag-updated.json" '
        .spec.tags |= map(if .name == $tag then $response[0].tag else . end)
      ' "$workdir/baseline.json" > "$workdir/next.json"
      mv "$workdir/next.json" "$workdir/baseline.json"
      return
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
      diagnose "ART update failed (${reason}; exit ${update_exit}); outcome unconfirmed, not retrying or attributing to another writer"
      exit "$update_exit"
    fi
  done
  diagnose 'Unable to update ART imports after three optimistic attempts'
  exit 1
}

wait_for_imports() {
  local attempt
  for ((attempt = 0; attempt < 60; attempt++)); do
    require_ci_promotion
    get_stream
    require_unchanged "$workdir/updated.json" 'Publication superseded while waiting for import'
    if jq_art '
      def import_failed($spec):
        any(.status.tags[]?;
          .tag == $spec.name and any(.conditions[]?;
            .type == "ImportSuccess" and .status == "False" and
            .generation == $spec.generation));
      . as $stream | any(art_specs[]; . as $spec | $stream | import_failed($spec))
    ' -e "$workdir/current.json" > /dev/null; then
      diagnose 'ART image import failed'
      exit 1
    fi
    if jq_art '
      def import_complete($spec):
        any(.status.tags[]?;
          .tag == $spec.name and
          (.items[0].image // "") != "" and
          .items[0].image == ($spec.from.name | split("@")[1]) and
          .items[0].generation == $spec.generation);
      . as $stream | art_specs |
      has_both_tags and all(.[]; . as $spec | $stream | import_complete($spec))
    ' -e "$workdir/current.json" > /dev/null; then
      require_ci_promotion
      echo 'Both ART CoreOS imports match this build and their current generations'
      return
    fi
    sleep 5
  done
  diagnose 'Timed out waiting for ART CoreOS imports'
  exit 1
}

validate_inputs
workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT
mirror_images
update_art_tags
wait_for_imports
