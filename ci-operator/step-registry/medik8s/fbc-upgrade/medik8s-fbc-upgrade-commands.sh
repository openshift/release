#!/bin/bash
set -o errexit -o nounset -o pipefail
# Inputs (defaults are declared in medik8s-fbc-upgrade-ref.yaml):
#   FBC_OPERATOR          Operator suite: nhc, sbr, snr, far, mdr, or nmo.
#   FBC_CHANNEL           Channel to upgrade through, usually stable.
#   FBC_CATALOG_MODE      latest-build (default), provided, or latest-stage.
#   SYSTEM_TESTS_REF      rhwa-system-tests branch, tag, or commit SHA.
#   ARTIFACT_DIR          Directory supplied by ci-operator for logs and results.
#
# provided mode uses FBC_CATALOG_IMAGE, FBC_CANDIDATE_VERSION,
# FBC_CANDIDATE_IMAGE, and FBC_CANDIDATE_MIRROR as configured by the job.
# latest-build uses FBC_BUILD_REPOSITORY; latest-stage uses FBC_STAGE_IMAGE.
# Both discovery modes read the version, controller, and mirrors from that release.
# Registry credentials come from the cluster pull secret, never from artifacts.

: "${ARTIFACT_DIR:?ci-operator must provide ARTIFACT_DIR}"
: "${FBC_CATALOG_MODE:=latest-build}"
case "$FBC_OPERATOR" in
  nhc) FBC_PACKAGE=node-healthcheck-operator ;;
  sbr) FBC_PACKAGE=storage-based-remediation ;;
  snr) FBC_PACKAGE=self-node-remediation ;;
  far) FBC_PACKAGE=fence-agents-remediation ;;
  mdr) FBC_PACKAGE=machine-deletion-remediation ;;
  nmo) FBC_PACKAGE=node-maintenance-operator ;;
  *) echo "Unsupported FBC_OPERATOR: $FBC_OPERATOR" >&2; exit 1 ;;
esac
exec > >(tee "$ARTIFACT_DIR/$FBC_OPERATOR-fbc-upgrade-tests.log") 2>&1

prepare_runtime() {
  echo '==> Read cluster pull secret for Red Hat registry access'
  local auth_dir=/tmp/fbc-registry-auth
  mkdir -p "$auth_dir"
  oc get secret pull-secret -n openshift-config -o jsonpath='{.data.\.dockerconfigjson}' |
    base64 --decode > "$auth_dir/auth.json"
  chmod 0600 "$auth_dir/auth.json"
  export REGISTRY_AUTH_FILE="$auth_dir/auth.json"

  # The test container runs as an arbitrary UID.
  export GOPATH=/tmp/fbc-go
  export GOMODCACHE="$GOPATH/pkg/mod"
  export GOCACHE=/tmp/fbc-go-build-cache
  mkdir -p "$GOMODCACHE" "$GOCACHE"
  go version
  skopeo --version
}

inspect_release_image() {
  # Public builds do not need credentials. The stage registry does.
  if [[ "$FBC_CATALOG_MODE" != latest-stage ]]; then
    skopeo inspect --no-tags --no-creds "$@"
  else
    skopeo inspect --no-tags "$@"
  fi
}

select_latest_build() {
  local repository page response tags_file digest
  repository="${FBC_BUILD_REPOSITORY#quay.io/}"
  page=1
  tags_file="$(mktemp)"

  # The Quay API takes a repository path, without the registry, tag, or digest.
  [[ "$FBC_BUILD_REPOSITORY" == quay.io/* && "$repository" != *[:@?]* ]]

  # Fetch every page before choosing a build; API order is not build order.
  while true; do
    response="$(
      curl --fail --silent --show-error --max-time 60 \
        --retry 3 --retry-delay 5 \
        "https://quay.io/api/v1/repository/$repository/tag/?onlyActiveTags=true&limit=100&page=$page"
    )"
    jq -e '
      (.tags | type == "array") and
      (.has_additional | type == "boolean")
    ' <<< "$response" > /dev/null
    jq -c '.tags[]' <<< "$response" >> "$tags_file"

    if [[ "$(jq -r '.has_additional' <<< "$response")" == false ]]; then
      break
    fi
    page=$((page + 1))
  done

  # Main builds have full commit-SHA tags. PR tags and OCI attachments do not.
  # Require all architectures to be present, then choose by publication time.
  jq -s '
    map(
      select(.name | test("^[0-9a-f]{40}$")) |
      select(.is_manifest_list) |
      select(.child_manifest_count > 0) |
      select(.present_child_count == .child_manifest_count) |
      {name, manifest_digest, start_ts}
    ) |
    max_by(.start_ts)
  ' "$tags_file" > "$ARTIFACT_DIR/fbc-build.json"

  jq -e '
    . != null and
    (.start_ts | type == "number") and
    (.manifest_digest | test("^sha256:[0-9a-f]{64}$"))
  ' "$ARTIFACT_DIR/fbc-build.json" > /dev/null

  FBC_BUILD_REVISION="$(jq -r '.name' "$ARTIFACT_DIR/fbc-build.json")"
  digest="$(jq -r '.manifest_digest' "$ARTIFACT_DIR/fbc-build.json")"
  FBC_CATALOG_IMAGE="$FBC_BUILD_REPOSITORY@$digest"
}

read_build_idms() {
  local revision source_dir layer_digest layer_file

  # Do not combine a catalog with source files from a different commit.
  revision="$(
    skopeo inspect --no-creds --no-tags \
      --format '{{index .Labels "org.opencontainers.image.revision"}}' \
      "docker://$FBC_CATALOG_IMAGE"
  )"
  test "$revision" = "$FBC_BUILD_REVISION"

  # The Dragonfly clone task publishes the exact source tree as a public .git OCI artifact.
  source_dir="$(mktemp -d)"
  skopeo copy --all --src-no-creds "docker://$FBC_BUILD_REPOSITORY:$revision.git" "dir:$source_dir"
  jq -e '.layers | length == 1' "$source_dir/manifest.json" > /dev/null

  layer_digest="$(jq -er '.layers[0].digest' "$source_dir/manifest.json")"
  [[ "$layer_digest" =~ ^sha256:[0-9a-f]{64}$ ]]
  # skopeo's directory format names layer files by their SHA, without "sha256:".
  layer_file="$source_dir/${layer_digest#sha256:}"
  tar -xOf "$layer_file" ./.tekton/images-mirror-set.yaml > "$ARTIFACT_DIR/idms.yaml"

  yq -o=json '.' "$ARTIFACT_DIR/idms.yaml" |
    jq -e '
      .kind == "ImageDigestMirrorSet" and
      (.spec.imageDigestMirrors | length > 0)
    ' > /dev/null
}

read_stage_idms() {
  # Match release-info's generate-install-manifests.sh stage-registry prefix mapping.
  cat > "$ARTIFACT_DIR/idms.yaml" <<'EOF'
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: rhwa-stage-mirror
spec:
  imageDigestMirrors:
    - source: registry.redhat.io/workload-availability
      mirrors:
        - registry.stage.redhat.io/workload-availability
EOF
}

extract_operator_catalog() {
  local catalog_dir configs_path catalog_file
  local catalog_files=()

  echo "==> Read $FBC_PACKAGE from the selected catalog"
  catalog_dir="$(mktemp -d)"
  configs_path="$(
    inspect_release_image \
      --format '{{index .Labels "operators.operatorframework.io.index.configs.v1"}}' \
      "docker://$FBC_CATALOG_IMAGE"
  )"
  [[ "$configs_path" == /* && "$configs_path" != / ]]
  oc image extract "$FBC_CATALOG_IMAGE" --registry-config="$REGISTRY_AUTH_FILE" \
    --path="$configs_path/:$catalog_dir" --confirm

  mapfile -t catalog_files < <(
    find "$catalog_dir" -type f \( -name '*.yaml' -o -name '*.json' \) -print
  )
  test "${#catalog_files[@]}" -gt 0

  # Parse files separately: a full index can mix YAML and newline-delimited JSON.
  for catalog_file in "${catalog_files[@]}"; do
    yq eval -o=json -I=0 '.' "$catalog_file"
  done |
    jq -cs --arg package "$FBC_PACKAGE" '
      [.[] | select(.package == $package)]
    ' > "$ARTIFACT_DIR/operator-catalog.json"
}

select_candidate_bundle() {
  local head

  echo "==> Find the head bundle in channel $FBC_CHANNEL"
  # The head is the entry that no other entry replaces or skips.
  # Version-name sorting would get cases such as 5.9 -> 5.10 wrong.
  head="$(
    jq -er --arg channel "$FBC_CHANNEL" '
      [.[] | select(.schema == "olm.channel" and .name == $channel)] |
      if length != 1 then
        error("expected exactly one selected channel")
      else
        .[0].entries
      end |

      [.[].name] as $bundle_names |
      [.[] | (.replaces // empty), (.skips[]?)] as $older_bundles |
      ($bundle_names - $older_bundles) | unique |
      if length != 1 then
        error("channel must have exactly one head")
      else
        .[0]
      end
    ' "$ARTIFACT_DIR/operator-catalog.json"
  )"

  jq -e --arg head "$head" '
    [.[] | select(.schema == "olm.bundle" and .name == $head)] |
    if length != 1 then
      error("expected exactly one head bundle")
    else
      .[0]
    end
  ' "$ARTIFACT_DIR/operator-catalog.json" > "$ARTIFACT_DIR/candidate-bundle.json"
}

read_candidate_metadata() {
  FBC_CANDIDATE_VERSION="$(
    jq -er '
      [.properties[] | select(.type == "olm.package") | .value.version] |
      if length != 1 or (.[0] | type) != "string" or .[0] == "" then
        error("missing or ambiguous bundle version")
      else
        .[0]
      end
    ' "$ARTIFACT_DIR/candidate-bundle.json"
  )"

  FBC_CANDIDATE_IMAGE="$(
    jq -er '
      [.properties[] |
        select(.type == "olm.csv.metadata") |
        .value.annotations.containerImage
      ] | unique |
      if length != 1 or (.[0] | type) != "string" then
        error("missing or ambiguous controller image")
      else
        .[0]
      end
    ' "$ARTIFACT_DIR/candidate-bundle.json"
  )"

  # Confirm the controller annotation points to an image actually in the bundle.
  jq -e --arg image "$FBC_CANDIDATE_IMAGE" '
    any(.relatedImages[]; .image == $image)
  ' "$ARTIFACT_DIR/candidate-bundle.json" > /dev/null
}

discover_candidate() {
  extract_operator_catalog
  select_candidate_bundle
  read_candidate_metadata
  find_controller_mirror
}

find_controller_mirror() {
  local repository digest source suffix mirror mirrors_file
  # Split the controller pullspec into its repository and digest at the "@".
  repository="${FBC_CANDIDATE_IMAGE%@*}"
  digest="${FBC_CANDIDATE_IMAGE##*@}"
  [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]]

  # IDMS can map a whole namespace or one repository. Use the most specific match.
  source="$(
    yq -o=json '.' "$ARTIFACT_DIR/idms.yaml" |
      jq -er --arg repository "$repository" '
        [.spec.imageDigestMirrors[] |
          .source as $source |
          select(
            $repository == $source or
            ($repository | startswith($source + "/"))
          )
        ] |
        sort_by(.source | length) | last | .source
      '
  )"

  # Keep the repository suffix when the IDMS maps a parent namespace.
  suffix="${repository#"$source"}"
  mirrors_file="$(mktemp)"
  yq -o=json '.' "$ARTIFACT_DIR/idms.yaml" |
    jq -r --arg source "$source" '
      .spec.imageDigestMirrors[] | select(.source == $source) | .mirrors[]
    ' > "$mirrors_file"

  echo '==> Find a release mirror serving the exact controller digest'
  while IFS= read -r mirror; do
    mirror="$mirror$suffix"
    # Older-version mirrors may lack this digest. Keep failed probes in artifacts.
    if inspect_release_image --format '{{.Digest}}' "docker://$mirror@$digest" \
      >> "$ARTIFACT_DIR/controller-mirror-probes.log" 2>&1; then
      FBC_CANDIDATE_MIRROR="$mirror"
      return
    fi
  done < "$mirrors_file"

  echo "No release mirror serves candidate controller $FBC_CANDIDATE_IMAGE" >&2
  return 1
}

write_idms() {
  # Exact .tekton/images-mirror-set.yaml from the pinned catalog's source:
  # https://gitlab.cee.redhat.com/dragonfly/rhwa-fbc/-/blob/8c9972727d69b2abf9312ddc9e9b270aaf67597c/.tekton/images-mirror-set.yaml
  # Keep this and the catalog/controller digests in sync when updating the FBC.
  echo '==> Write release IDMS for all six operators'
  cat <<'EOF' > "$ARTIFACT_DIR/idms.yaml"
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: rhwa-fbc-fips-image-mirror-set
spec:
  imageDigestMirrors:
    - mirrors:
        - quay.io/redhat-user-workloads/rhwa-tenant/node-healthcheck-operator/nhc-operator-0-10
        - quay.io/redhat-user-workloads/rhwa-tenant/node-healthcheck-operator/nhc-operator-0-11
        - quay.io/redhat-user-workloads/rhwa-tenant/node-healthcheck-operator/nhc-operator-0-12
        - quay.io/redhat-user-workloads/rhwa-tenant/node-healthcheck-operator/nhc-operator-5-8
      source: registry.redhat.io/workload-availability/node-healthcheck-rhel9-operator
    - mirrors:
        - quay.io/redhat-user-workloads/rhwa-tenant/node-healthcheck-operator/nhc-bundle-0-10
        - quay.io/redhat-user-workloads/rhwa-tenant/node-healthcheck-operator/nhc-bundle-0-11
        - quay.io/redhat-user-workloads/rhwa-tenant/node-healthcheck-operator/nhc-bundle-0-12
        - quay.io/redhat-user-workloads/rhwa-tenant/node-healthcheck-operator/nhc-bundle-5-8
      source: registry.redhat.io/workload-availability/node-healthcheck-operator-bundle
    - mirrors:
        - quay.io/redhat-user-workloads/rhwa-tenant/node-healthcheck-operator/nhc-console-0-10
        - quay.io/redhat-user-workloads/rhwa-tenant/node-healthcheck-operator/nhc-console-0-11
        - quay.io/redhat-user-workloads/rhwa-tenant/node-healthcheck-operator/nhc-console-0-12
        - quay.io/redhat-user-workloads/rhwa-tenant/node-healthcheck-operator/nhc-console-5-8
      source: registry.redhat.io/workload-availability/node-remediation-console-rhel9
    - mirrors:
        - quay.io/redhat-user-workloads/rhwa-tenant/node-healthcheck-operator/nhc-must-gather-0-10
        - quay.io/redhat-user-workloads/rhwa-tenant/node-healthcheck-operator/nhc-must-gather-0-11
        - quay.io/redhat-user-workloads/rhwa-tenant/node-healthcheck-operator/nhc-must-gather-0-12
        - quay.io/redhat-user-workloads/rhwa-tenant/node-healthcheck-operator/nhc-must-gather-5-8
      source: registry.redhat.io/workload-availability/node-healthcheck-must-gather-rhel9
    - mirrors:
        - quay.io/redhat-user-workloads/rhwa-tenant/self-node-remediation/snr-operator-0-11
        - quay.io/redhat-user-workloads/rhwa-tenant/self-node-remediation/snr-operator-0-12
        - quay.io/redhat-user-workloads/rhwa-tenant/self-node-remediation/snr-operator-0-13
        - quay.io/redhat-user-workloads/rhwa-tenant/self-node-remediation/snr-operator-5-8
      source: registry.redhat.io/workload-availability/self-node-remediation-rhel9-operator
    - mirrors:
        - quay.io/redhat-user-workloads/rhwa-tenant/self-node-remediation/snr-bundle-0-11
        - quay.io/redhat-user-workloads/rhwa-tenant/self-node-remediation/snr-bundle-0-12
        - quay.io/redhat-user-workloads/rhwa-tenant/self-node-remediation/snr-bundle-0-13
        - quay.io/redhat-user-workloads/rhwa-tenant/self-node-remediation/snr-bundle-5-8
      source: registry.redhat.io/workload-availability/self-node-remediation-operator-bundle
    - mirrors:
        - quay.io/redhat-user-workloads/rhwa-tenant/fence-agents-remediation/far-operator-0-6
        - quay.io/redhat-user-workloads/rhwa-tenant/fence-agents-remediation/far-operator-0-7
        - quay.io/redhat-user-workloads/rhwa-tenant/fence-agents-remediation/far-operator-0-8
        - quay.io/redhat-user-workloads/rhwa-tenant/fence-agents-remediation/far-operator-5-8
      source: registry.redhat.io/workload-availability/fence-agents-remediation-rhel9-operator
    - mirrors:
        - quay.io/redhat-user-workloads/rhwa-tenant/fence-agents-remediation/far-bundle-0-6
        - quay.io/redhat-user-workloads/rhwa-tenant/fence-agents-remediation/far-bundle-0-7
        - quay.io/redhat-user-workloads/rhwa-tenant/fence-agents-remediation/far-bundle-0-8
        - quay.io/redhat-user-workloads/rhwa-tenant/fence-agents-remediation/far-bundle-5-8
      source: registry.redhat.io/workload-availability/fence-agents-remediation-operator-bundle
    - mirrors:
        - quay.io/redhat-user-workloads/rhwa-tenant/machine-deletion-remediation/mdr-operator-0-5
        - quay.io/redhat-user-workloads/rhwa-tenant/machine-deletion-remediation/mdr-operator-0-6
        - quay.io/redhat-user-workloads/rhwa-tenant/machine-deletion-remediation/mdr-operator-0-7
        - quay.io/redhat-user-workloads/rhwa-tenant/machine-deletion-remediation/mdr-operator-5-8
      source: registry.redhat.io/workload-availability/machine-deletion-remediation-rhel9-operator
    - mirrors:
        - quay.io/redhat-user-workloads/rhwa-tenant/machine-deletion-remediation/mdr-bundle-0-5
        - quay.io/redhat-user-workloads/rhwa-tenant/machine-deletion-remediation/mdr-bundle-0-6
        - quay.io/redhat-user-workloads/rhwa-tenant/machine-deletion-remediation/mdr-bundle-0-7
        - quay.io/redhat-user-workloads/rhwa-tenant/machine-deletion-remediation/mdr-bundle-5-8
      source: registry.redhat.io/workload-availability/machine-deletion-remediation-operator-bundle
    - mirrors:
        - quay.io/redhat-user-workloads/rhwa-tenant/node-maintenance-operator/nmo-operator-5-5
        - quay.io/redhat-user-workloads/rhwa-tenant/node-maintenance-operator/nmo-operator-5-6
        - quay.io/redhat-user-workloads/rhwa-tenant/node-maintenance-operator/nmo-operator-5-7
        - quay.io/redhat-user-workloads/rhwa-tenant/node-maintenance-operator/nmo-operator-5-8
      source: registry.redhat.io/workload-availability/node-maintenance-rhel9-operator
    - mirrors:
        - quay.io/redhat-user-workloads/rhwa-tenant/node-maintenance-operator/nmo-bundle-5-5
        - quay.io/redhat-user-workloads/rhwa-tenant/node-maintenance-operator/nmo-bundle-5-6
        - quay.io/redhat-user-workloads/rhwa-tenant/node-maintenance-operator/nmo-bundle-5-7
        - quay.io/redhat-user-workloads/rhwa-tenant/node-maintenance-operator/nmo-bundle-5-8
      source: registry.redhat.io/workload-availability/node-maintenance-operator-bundle
    - mirrors:
        - quay.io/redhat-user-workloads/rhwa-tenant/storage-based-remediation/sbr-agent-0-3
        - quay.io/redhat-user-workloads/rhwa-tenant/storage-based-remediation/sbr-agent-5-8
      source: registry.redhat.io/workload-availability/storage-based-remediation-agent-rhel9
    - mirrors:
        - quay.io/redhat-user-workloads/rhwa-tenant/storage-based-remediation/sbr-operator-0-3
        - quay.io/redhat-user-workloads/rhwa-tenant/storage-based-remediation/sbr-operator-5-8
      source: registry.redhat.io/workload-availability/storage-based-remediation-rhel9-operator
    - mirrors:
        - quay.io/redhat-user-workloads/rhwa-tenant/storage-based-remediation/sbr-bundle-0-3
        - quay.io/redhat-user-workloads/rhwa-tenant/storage-based-remediation/sbr-bundle-5-8
      source: registry.redhat.io/workload-availability/storage-based-remediation-operator-bundle
EOF
}

prepare_candidate() {
  case "$FBC_CATALOG_MODE" in
    provided)
      write_idms
      ;;
    latest-build)
      echo '==> Discover the latest complete main-branch FBC build'
      select_latest_build
      read_build_idms
      discover_candidate
      ;;
    latest-stage)
      echo '==> Resolve the current stage index and discover its channel head'
      FBC_CATALOG_IMAGE="$(
        inspect_release_image --format '{{.Name}}@{{.Digest}}' "docker://$FBC_STAGE_IMAGE"
      )"
      read_stage_idms
      discover_candidate
      ;;
    *)
      echo "Unsupported FBC_CATALOG_MODE: $FBC_CATALOG_MODE" >&2
      return 1
      ;;
  esac

  # Use the supplied FBC; this job does not build operator or bundle images.
  local prefix="${FBC_OPERATOR^^}_FBC"
  export "${prefix}_CATALOG_IMAGE=$FBC_CATALOG_IMAGE"
  export "${prefix}_CANDIDATE_VERSION=$FBC_CANDIDATE_VERSION"
  export "${prefix}_CANDIDATE_IMAGE=$FBC_CANDIDATE_IMAGE"
  export "${prefix}_CHANNEL=$FBC_CHANNEL"
  export "${prefix}_IDMS_PATH=$ARTIFACT_DIR/idms.yaml"

  echo '==> Verify the supplied catalog is pullable before running tests'
  inspect_release_image --format '{{.Digest}}' "docker://$FBC_CATALOG_IMAGE"

  echo '==> Verify the exact controller digest at its public release mirror'
  local digest="${FBC_CANDIDATE_IMAGE##*@}"
  [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]]
  test -n "$FBC_CANDIDATE_MIRROR"
  if [[ "$FBC_CATALOG_MODE" == provided ]]; then
    grep -Fq -- "- $FBC_CANDIDATE_MIRROR" "$ARTIFACT_DIR/idms.yaml"
  fi
  inspect_release_image --format '{{.Digest}}' \
    "docker://$FBC_CANDIDATE_MIRROR@$digest"
  jq -n \
    --arg mode "$FBC_CATALOG_MODE" \
    --arg catalog "$FBC_CATALOG_IMAGE" \
    --arg version "$FBC_CANDIDATE_VERSION" \
    --arg controller "$FBC_CANDIDATE_IMAGE" \
    --arg mirror "$FBC_CANDIDATE_MIRROR" '
      {mode: $mode, catalog: $catalog, version: $version, controller: $controller, mirror: $mirror}
    ' > "$ARTIFACT_DIR/candidate-images.json"
}

checkout_system_tests() {
  local ref="${SYSTEM_TESTS_REF:-main}"
  echo "==> Check out openshift/rhwa-system-tests $ref"
  test ! -e /tmp/system-tests
  # Fetch only the requested branch, tag, or SHA without requiring newer git clone --revision support.
  git init /tmp/system-tests
  git -C /tmp/system-tests remote add origin https://github.com/openshift/rhwa-system-tests.git
  git -C /tmp/system-tests fetch --depth=1 origin "$ref"
  git -C /tmp/system-tests checkout --detach FETCH_HEAD
  git -C /tmp/system-tests show --no-patch --format=fuller HEAD
  git -C /tmp/system-tests rev-parse HEAD > "$ARTIFACT_DIR/system-tests-commit.txt"
}

print_run_config() {
  echo "Operator: $FBC_OPERATOR"
  echo "Catalog mode: $FBC_CATALOG_MODE"
  echo "Candidate catalog: $FBC_CATALOG_IMAGE"
  echo "Candidate version: $FBC_CANDIDATE_VERSION"
  echo "Candidate controller: $FBC_CANDIDATE_IMAGE"
  echo "Controller mirror: $FBC_CANDIDATE_MIRROR"
  echo "Channel: $FBC_CHANNEL"
  echo "IDMS: $ARTIFACT_DIR/idms.yaml"
}

run_upgrade_test() {
  export ECO_TEST_FEATURES="$FBC_OPERATOR-operator"
  export ECO_TEST_LABELS=tier:upgrade-operator
  export ECO_TEST_VERBOSE=true
  export WORKLOAD_IMAGE=registry.access.redhat.com/ubi9/ubi-minimal:latest

  # Match the proven source jobs' operator-specific safety settings.
  case "$FBC_OPERATOR" in
    nhc) export MEDIK8S_KUBELET_STOP_OCDEBUG=true ;;
    # Keep upgrade/config checks; skip the optional RWX-backed reboot test.
    sbr) export SBR_FBC_REMEDIATION=false; unset SBR_STORAGE_CLASS ;;
    # Keep upgrade/config checks; skip optional real fencing and its credentials.
    far) export FAR_FBC_REMEDIATION=false ;;
  esac

  echo '==> Start system-tests tier: upgrade-operator'
  export ECO_REPORTS_DUMP_DIR="$ARTIFACT_DIR/upgrade-operator"
  mkdir -p "$ECO_REPORTS_DUMP_DIR"
  make -C /tmp/system-tests run-tests 2>&1 | tee "$ECO_REPORTS_DUMP_DIR/run.log"
}

main() {
  prepare_runtime
  prepare_candidate
  checkout_system_tests
  print_run_config
  run_upgrade_test
}

main
