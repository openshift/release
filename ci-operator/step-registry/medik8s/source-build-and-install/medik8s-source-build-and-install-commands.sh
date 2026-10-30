#!/bin/bash
set -o errexit -o nounset -o pipefail
# Inputs supplied by the CI job and step registry:
#
#   SOURCE_OPERATOR            Required: nhc, sbr, snr, far, mdr, or nmo.
#   ARTIFACT_DIR               Required: writable directory for logs/reports.
#   BUILD_ID                   Required: Prow run ID used to isolate ttl.sh tags.
#   KUBECONFIG                 Required: cluster credentials for oc / operator-sdk.
#   PEER_BUNDLES               Optional: __default__ | "" | pkg[=image],...
#   OO_INSTALL_NAMESPACE       Optional: default openshift-workload-availability.
#   OO_INSTALL_TIMEOUT_MINUTES Optional: default 10.
#
# The runner contains Prow's selected source at /opt/<operator>-ci-src
# (typically a PR checkout for cross-repo system-tests jobs).

: "${ARTIFACT_DIR:?ci-operator must provide ARTIFACT_DIR}"
: "${BUILD_ID:?ci-operator must provide BUILD_ID}"
: "${SOURCE_OPERATOR:?SOURCE_OPERATOR must be set}"

OO_INSTALL_NAMESPACE="${OO_INSTALL_NAMESPACE:-openshift-workload-availability}"
OO_INSTALL_TIMEOUT_MINUTES="${OO_INSTALL_TIMEOUT_MINUTES:-10}"
PEER_BUNDLES="${PEER_BUNDLES:-__default__}"

case "$SOURCE_OPERATOR" in
  nhc)
    GA_BUNDLE_NAME=node-healthcheck-operator-bundle
    OLM_PACKAGE=node-healthcheck-operator
    ;;
  sbr)
    GA_BUNDLE_NAME=storage-based-remediation-operator-bundle
    OLM_PACKAGE=storage-based-remediation
    ;;
  snr)
    GA_BUNDLE_NAME=self-node-remediation-operator-bundle
    OLM_PACKAGE=self-node-remediation
    ;;
  far)
    GA_BUNDLE_NAME=fence-agents-remediation-operator-bundle
    OLM_PACKAGE=fence-agents-remediation
    ;;
  mdr)
    GA_BUNDLE_NAME=machine-deletion-remediation-operator-bundle
    OLM_PACKAGE=machine-deletion-remediation
    ;;
  nmo)
    GA_BUNDLE_NAME=node-maintenance-operator-bundle
    OLM_PACKAGE=node-maintenance-operator
    ;;
  *)
    echo "Unsupported SOURCE_OPERATOR: $SOURCE_OPERATOR" >&2
    exit 1
    ;;
esac

exec > >(tee "$ARTIFACT_DIR/$SOURCE_OPERATOR-source-build-and-install.log") 2>&1

resolve_peer_bundles() {
  if [[ "$PEER_BUNDLES" == "__default__" ]]; then
    case "$SOURCE_OPERATOR" in
      nhc)
        PEER_BUNDLES="self-node-remediation=quay.io/medik8s/self-node-remediation-operator-bundle:latest"
        ;;
      snr|mdr)
        PEER_BUNDLES="node-healthcheck-operator=quay.io/medik8s/node-healthcheck-operator-bundle:latest"
        ;;
      *)
        PEER_BUNDLES=""
        ;;
    esac
  fi
}

prepare_runtime() {
  echo '==> Read cluster pull secret for Red Hat registry access'
  local auth_dir="/tmp/$SOURCE_OPERATOR-registry-auth"
  mkdir -p "$auth_dir"
  oc get secret pull-secret \
    -n openshift-config \
    -o jsonpath='{.data.\.dockerconfigjson}' |
    base64 --decode > "$auth_dir/auth.json"
  chmod 0600 "$auth_dir/auth.json"
  export REGISTRY_AUTH_FILE="$auth_dir/auth.json"

  # The test container runs as an arbitrary UID.
  export GOPATH="/tmp/$SOURCE_OPERATOR-go"
  export GOMODCACHE="$GOPATH/pkg/mod"
  export GOCACHE="/tmp/$SOURCE_OPERATOR-go-build-cache"
  mkdir -p "$GOMODCACHE" "$GOCACHE"

  go version
  skopeo --version
  operator-sdk version
  podman version
  podman info

  echo '==> Configure rootless Podman for the catalog base image UID'
  local storage_config
  storage_config="$(podman info --format '{{.Store.ConfigFile}}')"
  test -r "$storage_config"
  export CONTAINERS_STORAGE_CONF="/tmp/$SOURCE_OPERATOR-storage.conf"

  awk '
    /^\[storage.options.overlay\]$/ {
      in_overlay = 1
      found = 1
      print
      print "ignore_chown_errors = \"true\""
      next
    }

    /^\[/ {
      in_overlay = 0
    }

    in_overlay && /^[[:space:]]*ignore_chown_errors[[:space:]]*=/ {
      next
    }

    {
      print
    }

    END {
      if (!found) {
        print "[storage.options.overlay]"
        print "ignore_chown_errors = \"true\""
      }
    }
  ' "$storage_config" > "$CONTAINERS_STORAGE_CONF"

  test "$(podman info --format '{{.Store.ConfigFile}}')" = "$CONTAINERS_STORAGE_CONF"

  echo '==> Pull catalog base image before building the candidate'
  # Match the default base image in the shared target's generated catalog Dockerfile.
  podman pull quay.io/operator-framework/opm:latest
}

build_candidate() {
  echo "==> Copy the CI-selected $SOURCE_OPERATOR checkout into a writable build directory"
  local source_dir="/tmp/$SOURCE_OPERATOR-source"
  test -f "/opt/$SOURCE_OPERATOR-ci-src/Makefile"
  cp -R "/opt/$SOURCE_OPERATOR-ci-src" "$source_dir"

  local revision prefix operator_tag agent_tag bundle_tag catalog_tag
  revision="$(git -C "$source_dir" rev-parse HEAD)"
  git -C "$source_dir" show --no-patch --format=fuller HEAD
  printf '%s\n' "$revision" > "$ARTIFACT_DIR/$SOURCE_OPERATOR-source-commit.txt"

  cd "$source_dir"

  SOURCE_VERSION="$(sed -n 's/^DEFAULT_VERSION := //p' Makefile)"
  test -n "$SOURCE_VERSION"

  PREVIOUS_VERSION="$(
    skopeo list-tags "docker://registry.redhat.io/workload-availability/$GA_BUNDLE_NAME" |
      jq -r '.Tags[] | select(test("^v[0-9]+\\.[0-9]+\\.[0-9]+$"))' |
      sort -V |
      tail -n 1
  )"
  test -n "$PREVIOUS_VERSION"
  PREVIOUS_VERSION="${PREVIOUS_VERSION#v}"
  test "$SOURCE_VERSION" != "$PREVIOUS_VERSION"

  export "${SOURCE_OPERATOR^^}_VERSION=$SOURCE_VERSION"
  export "${SOURCE_OPERATOR^^}_PREVIOUS_VERSION=$PREVIOUS_VERSION"
  printf 'Candidate: %s; latest GA: %s\n' "$SOURCE_VERSION" "$PREVIOUS_VERSION"

  local extra_build_args=()
  if [[ "$SOURCE_OPERATOR" == nhc ]]; then
    echo '==> Resolve NHC related images to digest pullspecs'
    local console_tag must_gather_tag console_digest mg_digest
    console_tag="quay.io/medik8s/node-remediation-console:latest"
    must_gather_tag="quay.io/medik8s/must-gather:latest"
    console_digest="$(skopeo inspect --format '{{.Digest}}' "docker://$console_tag")"
    mg_digest="$(skopeo inspect --format '{{.Digest}}' "docker://$must_gather_tag")"
    test -n "$console_digest"
    test -n "$mg_digest"
    export CONSOLE_PLUGIN_IMAGE="quay.io/medik8s/node-remediation-console@$console_digest"
    export MUST_GATHER_IMAGE="quay.io/medik8s/must-gather@$mg_digest"
    printf 'CONSOLE_PLUGIN_IMAGE=%s\nMUST_GATHER_IMAGE=%s\n' \
      "$CONSOLE_PLUGIN_IMAGE" "$MUST_GATHER_IMAGE" |
      tee "$ARTIFACT_DIR/nhc-related-images.txt"
    extra_build_args=(
      "CONSOLE_PLUGIN_IMAGE=$CONSOLE_PLUGIN_IMAGE"
      "MUST_GATHER_IMAGE=$MUST_GATHER_IMAGE"
    )
  fi

  # Keep each job's temporary images separate; expire them after three hours.
  prefix="ttl.sh/$SOURCE_OPERATOR-prow-${BUILD_ID}-${revision:0:7}"
  operator_tag="${prefix}:3h"
  bundle_tag="${prefix}-bundle:3h"
  catalog_tag="${prefix}-catalog:3h"

  if [[ "$SOURCE_OPERATOR" == sbr ]]; then
    agent_tag="${prefix}-agent:3h"
    extra_build_args=("DEV_OLM_AGENT_IMAGE=$agent_tag")
  fi

  echo '==> Build and push candidate images with the shared target'
  make dev-olm-catalog-push \
    DEV_REGISTRY=ttl.sh \
    TTL_SH_TTL=3h \
    CONTAINER_TOOL=podman \
    DEV_IMG="$operator_tag" \
    DEV_OLM_BUNDLE_IMAGE="$bundle_tag" \
    DEV_OLM_CATALOG_IMAGE="$catalog_tag" \
    VERSION="$SOURCE_VERSION" \
    PREVIOUS_VERSION="$PREVIOUS_VERSION" \
    "${extra_build_args[@]}"

  echo '==> Resolve pushed candidate images to immutable digests'
  skopeo inspect --format '{{.Digest}}' \
    "docker://$operator_tag" > "$ARTIFACT_DIR/operator.digest"
  skopeo inspect --format '{{.Digest}}' \
    "docker://$bundle_tag" > "$ARTIFACT_DIR/bundle.digest"
  skopeo inspect --format '{{.Digest}}' \
    "docker://$catalog_tag" > "$ARTIFACT_DIR/catalog.digest"

  CANDIDATE_IMAGE="${prefix}@$(cat "$ARTIFACT_DIR/operator.digest")"
  CANDIDATE_BUNDLE="${prefix}-bundle@$(cat "$ARTIFACT_DIR/bundle.digest")"
  CANDIDATE_CATALOG="${prefix}-catalog@$(cat "$ARTIFACT_DIR/catalog.digest")"

  if [[ "$SOURCE_OPERATOR" == sbr ]]; then
    skopeo inspect --format '{{.Digest}}' \
      "docker://$agent_tag" > "$ARTIFACT_DIR/agent.digest"
    CANDIDATE_AGENT_IMAGE="${prefix}-agent@$(cat "$ARTIFACT_DIR/agent.digest")"
  fi

  {
    printf 'CANDIDATE_IMAGE=%s\n' "$CANDIDATE_IMAGE"
    if [[ "$SOURCE_OPERATOR" == sbr ]]; then
      printf 'CANDIDATE_AGENT_IMAGE=%s\n' "$CANDIDATE_AGENT_IMAGE"
    fi
    printf 'CANDIDATE_BUNDLE=%s\nCANDIDATE_CATALOG=%s\n' \
      "$CANDIDATE_BUNDLE" "$CANDIDATE_CATALOG"
  } | tee "$ARTIFACT_DIR/candidate-images.txt"
}

verify_candidate() {
  echo '==> Validate candidate bundle'
  operator-sdk bundle validate --image-builder=none "$CANDIDATE_BUNDLE"

  local bundle_dir candidate_csv candidate_version
  bundle_dir="$(mktemp -d)"
  oc image extract "$CANDIDATE_BUNDLE" \
    --path="/manifests/:$bundle_dir" \
    --confirm
  candidate_csv="$(find "$bundle_dir" -name '*clusterserviceversion.yaml' -print -quit)"
  : "${candidate_csv:?candidate bundle must contain a ClusterServiceVersion}"

  candidate_version="$(sed -n 's/^  version: *//p' "$candidate_csv" | tr -d '"')"
  : "${candidate_version:?candidate bundle CSV must specify spec.version}"
  test "$candidate_version" = "$SOURCE_VERSION"

  CANDIDATE_VERSION="$candidate_version"
  echo "==> Candidate bundle verified: version $candidate_version"
}

ensure_install_namespace() {
  echo "==> Ensure namespace ${OO_INSTALL_NAMESPACE}"
  oc create namespace "${OO_INSTALL_NAMESPACE}" --dry-run=client -o yaml | oc apply -f -
  oc label --overwrite "ns/${OO_INSTALL_NAMESPACE}" \
    security.openshift.io/scc.podSecurityLabelSync=false \
    pod-security.kubernetes.io/enforce=privileged
}

wait_for_package_csv() {
  local package="$1"
  echo "==> Wait for CSV Succeeded ($package) in ${OO_INSTALL_NAMESPACE}"
  local csv=""
  local attempts=$((OO_INSTALL_TIMEOUT_MINUTES * 6))
  local i sub
  for i in $(seq 1 "$attempts"); do
    while IFS= read -r sub; do
      [[ -z "$sub" ]] && continue
      if [[ "$(oc get subscription "$sub" -n "$OO_INSTALL_NAMESPACE" \
        -o jsonpath='{.spec.name}' 2>/dev/null)" == "$package" ]]; then
        csv=$(oc get subscription "$sub" -n "$OO_INSTALL_NAMESPACE" \
          -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)
        if [[ -n "$csv" ]]; then
          break 2
        fi
      fi
    done < <(oc get subscription -n "$OO_INSTALL_NAMESPACE" \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
    echo "  attempt ${i}/${attempts} — installedCSV not set yet, waiting 10s..."
    sleep 10
  done
  : "${csv:?No CSV installed for $package}"
  echo "==> Waiting for CSV ${csv} to reach Succeeded"
  oc wait --for=jsonpath='{.status.phase}'=Succeeded "csv/${csv}" \
    -n "${OO_INSTALL_NAMESPACE}" --timeout="${OO_INSTALL_TIMEOUT_MINUTES}m"
}

install_bundle() {
  local package="$1"
  local bundle_image="$2"
  echo "==> Install $package from $bundle_image via operator-sdk run bundle"
  operator-sdk run bundle "$bundle_image" \
    -n "${OO_INSTALL_NAMESPACE}" \
    --verbose \
    --timeout="${OO_INSTALL_TIMEOUT_MINUTES}m"
  wait_for_package_csv "$package"
}

install_candidate() {
  ensure_install_namespace
  install_bundle "$OLM_PACKAGE" "$CANDIDATE_BUNDLE"
}

default_peer_bundle_image() {
  local pkg="$1"
  if [[ "$pkg" == *-operator ]]; then
    echo "quay.io/medik8s/${pkg}-bundle:latest"
  else
    echo "quay.io/medik8s/${pkg}-operator-bundle:latest"
  fi
}

install_peers() {
  resolve_peer_bundles
  if [[ -z "$PEER_BUNDLES" ]]; then
    echo '==> No peer bundles to install'
    return 0
  fi

  local entry pkg image
  IFS=',' read -r -a peer_entries <<< "$PEER_BUNDLES"
  for entry in "${peer_entries[@]}"; do
    [[ -z "$entry" ]] && continue
    if [[ "$entry" == *"="* ]]; then
      pkg="${entry%%=*}"
      image="${entry#*=}"
    else
      pkg="$entry"
      image="$(default_peer_bundle_image "$pkg")"
    fi
    : "${pkg:?peer entry must include a package name}"
    : "${image:?peer entry must resolve to a bundle image}"
    install_bundle "$pkg" "$image"
  done
}

main() {
  prepare_runtime
  build_candidate
  verify_candidate
  install_candidate
  install_peers
}

main
