#!/bin/bash
# Run locally with: bash hack/test-medik8s-fbc-discovery.sh
set -euo pipefail

if [[ "${1:-}" != --case ]]; then
  logs="$(mktemp -d)"
  for scenario in default-mode latest-build latest-stage provided mixed-format skip-edges missing-channel duplicate-channel \
    multiple-heads missing-bundle missing-version missing-controller wrong-related-image \
    missing-mirror unavailable-mirror invalid-digest empty-builds malformed-api bad-revision unavailable-source \
    registry-failure invalid-mode; do
    result=0
    bash "$0" --case "$scenario" > "$logs/$scenario.log" 2>&1 || result=$?
    case "$scenario" in
      default-mode|latest-build|latest-stage|provided|mixed-format|skip-edges) expected=0 ;;
      unavailable-source) expected=43 ;;
      registry-failure) expected=42 ;;
      missing-channel|duplicate-channel|multiple-heads|missing-bundle|missing-version|missing-controller) expected=5 ;;
      *) expected=1 ;;
    esac
    if [[ "$result" != "$expected" ]]; then
      printf 'FAIL: %s (expected %s, received %s); log: %s\n' "$scenario" "$expected" "$result" "$logs/$scenario.log" >&2
      exit 1
    fi
    printf 'PASS: %s (exit %s)\n' "$scenario" "$result"
  done
  printf 'Fixture logs: %s\n' "$logs"
  exit
fi

scenario="$2"
test_dir="$(mktemp -d)"
export ARTIFACT_DIR="$test_dir/artifacts"
mkdir -p "$ARTIFACT_DIR"
export FBC_OPERATOR=nhc FBC_CHANNEL=stable FBC_CATALOG_MODE=latest-build
export FBC_BUILD_REPOSITORY=quay.io/example/catalog
export FBC_STAGE_IMAGE=registry.stage.redhat.io/redhat/redhat-operator-index:v5.0
export REGISTRY_AUTH_FILE="$test_dir/private-auth.json"
fixture_digest="sha256:$(printf '%064d' 1)"
fixture_revision="$(printf '%040d' 1)"
fixture_controller="registry.redhat.io/workload-availability/node-healthcheck-rhel9-operator@$fixture_digest"
export FBC_CATALOG_IMAGE="quay.io/example/catalog@$fixture_digest"
export FBC_CANDIDATE_VERSION=5.10.0 FBC_CANDIDATE_IMAGE="$fixture_controller"
export FBC_CANDIDATE_MIRROR=quay.io/redhat-user-workloads/rhwa-tenant/node-healthcheck-operator/nhc-operator-5-8

jq -n --arg image "$fixture_controller" '[
  {schema:"olm.channel", package:"node-healthcheck-operator", name:"stable", entries:[
    {name:"nhc.v5.9.0"}, {name:"nhc.v5.10.0", replaces:"nhc.v5.9.0"}]},
  {schema:"olm.bundle", package:"node-healthcheck-operator", name:"nhc.v5.10.0", properties:[
    {type:"olm.package", value:{version:"5.10.0"}},
    {type:"olm.csv.metadata", value:{annotations:{containerImage:$image}}}],
    relatedImages:[{name:"manager", image:$image}]}
]' > "$test_dir/catalog.json"

case "$scenario" in
  default-mode)
    # The default must discover the catalog and metadata, not use supplied pins.
    unset FBC_CATALOG_MODE FBC_CATALOG_IMAGE FBC_CANDIDATE_VERSION
    unset FBC_CANDIDATE_IMAGE FBC_CANDIDATE_MIRROR
    ;;
  latest-stage) FBC_CATALOG_MODE=latest-stage ;;
  provided) FBC_CATALOG_MODE=provided ;;
  missing-channel) FBC_CHANNEL=absent ;;
  skip-edges) mutation='.[0].entries[1].skips = ["nhc.v5.8.0"] | .[0].entries += [{name:"nhc.v5.8.0"}]' ;;
  duplicate-channel) mutation='. + [.[0]]' ;;
  multiple-heads) mutation='.[0].entries += [{name:"another-head"}]' ;;
  missing-bundle) mutation='map(select(.schema != "olm.bundle"))' ;;
  missing-version) mutation='.[1].properties |= map(select(.type != "olm.package"))' ;;
  missing-controller) mutation='.[1].properties |= map(select(.type != "olm.csv.metadata"))' ;;
  wrong-related-image) mutation='.[1].relatedImages = []' ;;
  invalid-digest) mutation='.[1].properties[1].value.annotations.containerImage = "registry.redhat.io/operator:latest" |
    .[1].relatedImages[0].image = "registry.redhat.io/operator:latest"' ;;
  invalid-mode) FBC_CATALOG_MODE=unsupported ;;
esac
if [[ -n "${mutation:-}" ]]; then
  jq "$mutation" "$test_dir/catalog.json" > "$test_dir/changed.json"
  mv "$test_dir/changed.json" "$test_dir/catalog.json"
fi

# Test the actual functions, without cluster setup, checkout, or the Go suite.
source <(sed '/^exec > /d; /^main$/d' \
  "$(dirname "$0")/../ci-operator/step-registry/medik8s/fbc-upgrade/medik8s-fbc-upgrade-commands.sh")

if [[ "$scenario" == default-mode ]]; then
  test "$FBC_CATALOG_MODE" = latest-build
  # Check Prow's declared default as well as the shell's standalone default.
  test "$(yq -r '.ref.env[] | select(.name == "FBC_CATALOG_MODE") | .default' \
    "$(dirname "$0")/../ci-operator/step-registry/medik8s/fbc-upgrade/medik8s-fbc-upgrade-ref.yaml")" = latest-build
fi

curl() {
  if [[ "$scenario" == malformed-api ]]; then echo '{}'; return; fi
  if [[ "$scenario" == empty-builds ]]; then echo '{"tags":[],"has_additional":false}'; return; fi
  if [[ "${*: -1}" == *page=1 ]]; then
    jq -n --arg revision "$fixture_revision" --arg digest "$fixture_digest" '{has_additional:true, tags:[
      {name:("on-pr-"+$revision), manifest_digest:$digest, start_ts:999, is_manifest_list:true,
        child_manifest_count:4, present_child_count:4},
      {name:("sha256-"+$digest+".att"), manifest_digest:$digest, start_ts:998, is_manifest_list:true,
        child_manifest_count:4, present_child_count:4},
      {name:"2222222222222222222222222222222222222222", manifest_digest:$digest, start_ts:997,
        is_manifest_list:true, child_manifest_count:4, present_child_count:3}]}'
  else
    jq -n --arg revision "$fixture_revision" --arg digest "$fixture_digest" '{has_additional:false, tags:[
      {name:$revision, manifest_digest:$digest, start_ts:10, is_manifest_list:true,
        child_manifest_count:4, present_child_count:4}]}'
  fi
}

skopeo() {
  if [[ "$scenario" == registry-failure ]]; then return 42; fi
  case "$1" in
    copy)
      if [[ "$scenario" == unavailable-source ]]; then return 43; fi
      local destination="${*: -1}"
      destination="${destination#dir:}"
      mkdir -p "$test_dir/tree/.tekton" "$destination"
      jq -n '{kind:"ImageDigestMirrorSet", spec:{imageDigestMirrors:[{
        source:"registry.redhat.io/workload-availability",
        mirrors:["quay.io/example/release"]}]}}' > "$test_dir/tree/.tekton/images-mirror-set.yaml"
      if [[ "$scenario" == missing-mirror ]]; then
        echo '{"kind":"ImageDigestMirrorSet","spec":{"imageDigestMirrors":[]}}' > "$test_dir/tree/.tekton/images-mirror-set.yaml"
      fi
      tar -cf "$destination/${fixture_digest#sha256:}" -C "$test_dir/tree" .
      jq -n --arg digest "$fixture_digest" '{layers:[{digest:$digest}]}' > "$destination/manifest.json"
      ;;
    inspect)
      if [[ "$scenario" == unavailable-mirror && "${*: -1}" == docker://quay.io/example/release* ]]; then
        return 44
      fi
      case "$*" in
        *org.opencontainers.image.revision*)
          if [[ "$scenario" == bad-revision ]]; then echo wrong; else echo "$fixture_revision"; fi ;;
        *index.configs.v1*) echo /configs ;;
        *'{{.Name}}@{{.Digest}}'*) echo "registry.stage.redhat.io/redhat/redhat-operator-index@$fixture_digest" ;;
        *)
          if [[ "$FBC_CATALOG_MODE" == latest-stage ]]; then
            [[ "$*" != *--no-creds* ]]
          else
            [[ "$*" == *--no-creds* ]]
          fi
          echo "$fixture_digest"
          ;;
      esac
      ;;
    *) return 99 ;;
  esac
}

oc() {
  test "$1 $2" = 'image extract'
  local argument destination=''
  for argument in "$@"; do
    if [[ "$argument" == --path=* ]]; then destination="${argument##*:}"; fi
  done
  test -d "$destination"
  if [[ "$scenario" == mixed-format ]]; then
    echo '{"schema":"olm.deprecations","package":"node-healthcheck-operator","entries":[]}' > "$destination/lifecycle.json"
    while IFS= read -r record; do
      printf '%s\n' '---'
      yq -p=json -o=yaml -P '.' <<< "$record"
    done < <(jq -c '.[]' "$test_dir/catalog.json") > "$destination/catalog.yaml"
  else
    jq -c '.[]' "$test_dir/catalog.json" > "$destination/catalog.json"
  fi
}

prepare_candidate
if [[ "$scenario" == default-mode ]]; then
  test -s "$ARTIFACT_DIR/fbc-build.json"
  jq -e '.mode == "latest-build"' "$ARTIFACT_DIR/candidate-images.json" > /dev/null
fi
test "$NHC_FBC_CANDIDATE_VERSION" = 5.10.0
test "$NHC_FBC_CANDIDATE_IMAGE" = "$fixture_controller"
test -s "$NHC_FBC_IDMS_PATH"
jq -e --arg digest "$fixture_digest" '.catalog | endswith($digest)' "$ARTIFACT_DIR/candidate-images.json" > /dev/null
