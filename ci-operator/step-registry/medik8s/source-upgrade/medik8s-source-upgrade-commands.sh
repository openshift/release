#!/bin/bash
set -o errexit -o nounset -o pipefail
# Inputs supplied by the CI job and step registry:
#
#   SOURCE_OPERATOR       Required: nhc, sbr, snr, far, mdr, or nmo.
#   ARTIFACT_DIR          Required: existing writable directory for logs/reports.
#   KUBECONFIG            Required: cluster credentials for oc and the Go tests.
#   CONSOLE_PLUGIN_IMAGE  NHC only: digest-pinned console image (default in ref).
#   MUST_GATHER_IMAGE     NHC only: digest-pinned must-gather image (default in ref).
#
# The runner contains Prow's selected source at /opt/<operator>-ci-src.
# Candidate versions come from that checkout; source images need no release IDMS.

: "${ARTIFACT_DIR:?ci-operator must provide ARTIFACT_DIR}"
case "$SOURCE_OPERATOR" in
  nhc)
    GA_BUNDLE_NAME=node-healthcheck-operator-bundle
    ;;
  sbr)
    GA_BUNDLE_NAME=storage-based-remediation-operator-bundle
    ;;
  snr)
    GA_BUNDLE_NAME=self-node-remediation-operator-bundle
    ;;
  far)
    GA_BUNDLE_NAME=fence-agents-remediation-operator-bundle
    ;;
  mdr)
    GA_BUNDLE_NAME=machine-deletion-remediation-operator-bundle
    ;;
  nmo)
    GA_BUNDLE_NAME=node-maintenance-operator-bundle
    ;;
  *)
    echo "Unsupported SOURCE_OPERATOR: $SOURCE_OPERATOR" >&2
    exit 1
    ;;
esac

exec > >(tee "$ARTIFACT_DIR/$SOURCE_OPERATOR-upgrade-tests.log") 2>&1

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

  if [[ "$SOURCE_OPERATOR" == nhc ]]; then
    echo '==> Verify pinned console plugin and must-gather images are pullable'
    skopeo inspect --format '{{.Digest}}' "docker://$CONSOLE_PLUGIN_IMAGE"
    skopeo inspect --format '{{.Digest}}' "docker://$MUST_GATHER_IMAGE"
  fi

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

  # Reuse the runner's SDK only when it matches this checkout's tool pin.
  local sdk_version required_sdk_version
  sdk_version="$(
    operator-sdk version |
      sed -n 's/^operator-sdk version: "\([^"]*\)".*/\1/p'
  )"
  required_sdk_version="$(sed -n 's/^OPERATOR_SDK_VERSION[[:space:]]*[?]*=[[:space:]]*//p' Makefile)"
  printf 'Operator SDK: %s; required by source: %s\n' \
    "$sdk_version" "$required_sdk_version"
  test -n "$required_sdk_version" &&
    test "$sdk_version" = "$required_sdk_version"

  # Read the candidate version from the selected checkout.
  SOURCE_VERSION="$(sed -n 's/^DEFAULT_VERSION := //p' Makefile)"
  test -n "$SOURCE_VERSION"

  if [[ "$SOURCE_OPERATOR" == nhc ]]; then
    local go_version
    go_version="$(sed -n 's/^[[:space:]]*Version = "\([^"]*\)".*/\1/p' version/version.go)"
    test "$SOURCE_VERSION" = "$go_version"
  fi

  # Use the latest released GA bundle as the upgrade baseline.
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

  # Keep each job's temporary images separate; expire them after three hours.
  prefix="ttl.sh/$SOURCE_OPERATOR-prow-$(date +%Y%m%d-%H%M%S)-${revision:0:7}"
  operator_tag="${prefix}:3h"
  bundle_tag="${prefix}-bundle:3h"
  catalog_tag="${prefix}-catalog:3h"

  # The common target owns bundle generation. Only these extra inputs differ.
  local extra_build_args=()
  case "$SOURCE_OPERATOR" in
    nhc)
      extra_build_args=(
        DOCS_RHWA_VERSION=5.0
        "CONSOLE_PLUGIN_IMAGE=$CONSOLE_PLUGIN_IMAGE"
        "MUST_GATHER_IMAGE=$MUST_GATHER_IMAGE"
      )
      ;;
    sbr)
      agent_tag="${prefix}-agent:3h"
      extra_build_args=("DEV_OLM_AGENT_IMAGE=$agent_tag")
      ;;
  esac

  echo '==> Build and push candidate images with the shared target'
  make dev-olm-catalog-push \
    OPERATOR_SDK=/usr/local/bin/operator-sdk \
    DEV_OLM_OPERATOR_SDK=/usr/local/bin/operator-sdk \
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

  candidate_version="$(
    sed -n 's/^  version: *//p' "$candidate_csv" |
      tr -d '"'
  )"
  : "${candidate_version:?candidate bundle CSV must specify spec.version}"
  test "$candidate_version" = "$SOURCE_VERSION"

  if [[ "$SOURCE_OPERATOR" == nhc ]]; then
    grep -Fq "$CONSOLE_PLUGIN_IMAGE" "$candidate_csv"
  fi

  CANDIDATE_VERSION="$candidate_version"
  echo "==> Candidate bundle verified: version $candidate_version"
}

prepare_candidate() {
  build_candidate
  verify_candidate

  # Feed the source-built FBC into the same Go test as the supplied release FBC.
  local prefix="${SOURCE_OPERATOR^^}_FBC"
  export "${prefix}_CATALOG_IMAGE=$CANDIDATE_CATALOG"
  export "${prefix}_CANDIDATE_VERSION=$CANDIDATE_VERSION"
  export "${prefix}_CANDIDATE_IMAGE=$CANDIDATE_IMAGE"
  export "${prefix}_CHANNEL=stable"

  # Source-built images are directly pullable from ttl.sh; no release IDMS.
  unset "${prefix}_IDMS_PATH"
}

checkout_system_tests() {
  echo '==> Check out openshift/rhwa-system-tests main'
  git clone --depth=1 --branch main \
    https://github.com/openshift/rhwa-system-tests.git /tmp/system-tests
  git -C /tmp/system-tests show --no-patch --format=fuller HEAD
  git -C /tmp/system-tests rev-parse HEAD > "$ARTIFACT_DIR/system-tests-commit.txt"
}

print_run_config() {
  echo "Operator: $SOURCE_OPERATOR"
  echo "Candidate catalog: $CANDIDATE_CATALOG"
  echo "Candidate version: $CANDIDATE_VERSION"
  echo "Candidate controller: $CANDIDATE_IMAGE"
  echo 'Channel: stable'
  echo 'IDMS: none'

  case "$SOURCE_OPERATOR" in
    sbr|far)
      echo 'Mode: upgrade/configuration persistence; remediation NOT REQUESTED'
      ;;
  esac
}

run_upgrade_test() {
  export ECO_TEST_FEATURES="$SOURCE_OPERATOR-operator"
  export ECO_TEST_LABELS=tier:upgrade-operator
  export ECO_TEST_VERBOSE=true

  # Preserve the existing jobs' workload and operator-specific safety settings.
  case "$SOURCE_OPERATOR" in
    nhc|sbr|snr)
      export WORKLOAD_IMAGE="unused-by-$SOURCE_OPERATOR-upgrade-tests"
      ;;
    *)
      export WORKLOAD_IMAGE=registry.access.redhat.com/ubi9/ubi-minimal:latest
      ;;
  esac

  case "$SOURCE_OPERATOR" in
    nhc)
      export MEDIK8S_KUBELET_STOP_OCDEBUG=true
      ;;
    sbr)
      export SBR_FBC_REMEDIATION=false
      unset SBR_STORAGE_CLASS
      ;;
    far)
      export FAR_FBC_REMEDIATION=false
      ;;
  esac

  echo '==> Start system-tests tier: upgrade-operator'
  export ECO_REPORTS_DUMP_DIR="$ARTIFACT_DIR/upgrade-operator"
  mkdir -p "$ECO_REPORTS_DUMP_DIR"
  make -C /tmp/system-tests run-tests 2>&1 |
    tee "$ECO_REPORTS_DUMP_DIR/run.log"
}

main() {
  prepare_runtime
  prepare_candidate
  checkout_system_tests
  print_run_config
  run_upgrade_test
}

main
