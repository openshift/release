#!/usr/bin/env bash
# Opt-in mock for OLM bundle-unpack diagnostic collection. No Make or CI target
# invokes it; run `bash hack/test-quay-deploy-aws-s3-olm-diagnostics.sh`.
# It covers successful queries with warnings, CatalogSource ownership filtering,
# resource and log bounds, and missing or failing resource queries.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${repo_root}/ci-operator/step-registry/quay/deploy-aws-s3/quay-deploy-aws-s3-commands.sh"
tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

mkdir -p "${tmpdir}/bin"
cat > "${tmpdir}/bin/oc" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case " $* " in
  *" get catalogsource quay-operator -o jsonpath="*) printf 'catalogsource-uid\n' ;;
  *" get catalogsource quay-operator -o yaml "*) printf 'kind: CatalogSource\n' ;;
  *" get configmap -o json "*)
    if [[ "${MOCK_SCENARIO}" == missing ]]; then
      printf '%s\n' '{"items":[{"metadata":{"name":"wrong-owner","ownerReferences":[{"kind":"CatalogSource","name":"other","uid":"catalogsource-uid"}]}}]}'
    else
      printf '%s\n' '{"items":[
        {"metadata":{"name":"bundle-new","creationTimestamp":"2026-04-01T00:00:00Z","ownerReferences":[{"kind":"CatalogSource","name":"quay-operator","uid":"catalogsource-uid"}]}},
        {"metadata":{"name":"bundle-mid","creationTimestamp":"2026-03-01T00:00:00Z","ownerReferences":[{"kind":"CatalogSource","name":"quay-operator","uid":"catalogsource-uid"}]}},
        {"metadata":{"name":"bundle-old","creationTimestamp":"2026-02-01T00:00:00Z","ownerReferences":[{"kind":"CatalogSource","name":"quay-operator","uid":"catalogsource-uid"}]}},
        {"metadata":{"name":"bundle-excess","creationTimestamp":"2026-01-01T00:00:00Z","ownerReferences":[{"kind":"CatalogSource","name":"quay-operator","uid":"catalogsource-uid"}]}},
        {"metadata":{"name":"wrong-uid","ownerReferences":[{"kind":"CatalogSource","name":"quay-operator","uid":"old-uid"}]}},
        {"metadata":{"name":"unrelated","ownerReferences":[{"kind":"CatalogSource","name":"other","uid":"catalogsource-uid"}]}}
      ]}'
    fi
    printf 'Warning: configmap query succeeded with a warning\n' >&2
    ;;
  *" get jobs "*)
    if [[ "${MOCK_SCENARIO}" == failing ]]; then
      printf 'jobs query failed\n' >&2
      exit 1
    fi
    printf '%s\n' '{"items":[{"metadata":{"name":"bundle-unpack-hash"}}]}'
    printf 'Warning: jobs query succeeded with a warning\n' >&2
    ;;
  *" get pods "*)
    if [[ "${MOCK_SCENARIO}" == failing ]]; then
      printf 'pods query failed\n' >&2
      exit 1
    fi
    if [[ " $* " == *"bundle-new"* ]]; then
      printf '%s\n' '{"items":[
        {"metadata":{"name":"bundle-pod-one"},"spec":{"initContainers":[{"name":"init-one"}],"containers":[{"name":"main-one"}]}},
        {"metadata":{"name":"bundle-pod-two"},"spec":{"initContainers":[{"name":"init-two"}],"containers":[{"name":"main-two"}]}},
        {"metadata":{"name":"bundle-pod-three"},"spec":{"containers":[{"name":"main-three"}]}},
        {"metadata":{"name":"bundle-pod-excess"},"spec":{"containers":[{"name":"main-excess"}]}}
      ]}'
    else
      printf '%s\n' '{"items":[]}'
    fi
    printf 'Warning: pods query succeeded with a warning\n' >&2
    ;;
  *" get events "*) printf 'events\n' ;;
  *" logs "*) printf 'collected logs for %s\n' "$*" ;;
  *" get subscription "*|*" get installplan "*|*" get csv "*) printf 'kind: List\n' ;;
  *)
    printf 'unexpected oc invocation: %s\n' "$*" >&2
    exit 1
    ;;
esac
EOF
chmod +x "${tmpdir}/bin/oc"

awk '
  /^QUAY_NS=/ { emit = 1 }
  emit { print }
  emit && /^}$/ { exit }
' "${script}" > "${tmpdir}/archive-function.sh"
# shellcheck disable=SC1090
source "${tmpdir}/archive-function.sh"

PATH="${tmpdir}/bin:${PATH}"
export QUAY_OPERATOR_SOURCE="quay-operator"
run_collection() {
  ARTIFACT_DIR="$1"
  mkdir -p "${ARTIFACT_DIR}"
  archive_olm_bundle_unpack_diagnostics
}

export MOCK_SCENARIO=warnings
run_collection "${tmpdir}/warnings"
root="${ARTIFACT_DIR}/olm-bundle-unpack"
jq -e '[.[].name] == ["bundle-new", "bundle-mid", "bundle-old", "bundle-excess"]' \
  "${root}/selected-bundle-configmaps.json" >/dev/null
jq -e '.items[0].metadata.name == "bundle-unpack-hash"' "${root}/bundle-new-jobs.json" >/dev/null
jq -e '.items[0].metadata.name == "bundle-pod-one"' "${root}/bundle-new-pods.json" >/dev/null
grep -qx 'Warning: configmap query succeeded with a warning' "${root}/catalog-configmaps.err"
grep -qx 'Warning: jobs query succeeded with a warning' "${root}/bundle-new-jobs.err"
grep -qx 'Warning: pods query succeeded with a warning' "${root}/bundle-new-pods.err"
test -s "${root}/bundle-new-job-events.txt"
test -s "${root}/bundle-pod-one_events.txt"
test -f "${root}/bundle-pod-one_init-one.log"
test -f "${root}/bundle-pod-one_main-one.log"
test -f "${root}/bundle-pod-two_init-two.log"
test -f "${root}/bundle-pod-two_main-two.log"
test ! -e "${root}/bundle-pod-one_main-two.log"
test -f "${root}/pod-log-cap.txt"
test ! -e "${root}/bundle-pod-excess_main-excess.log"
test -f "${root}/bundle-reference-cap.txt"
test ! -e "${root}/bundle-excess-jobs.json"

export MOCK_SCENARIO=missing
run_collection "${tmpdir}/missing"
test -f "${ARTIFACT_DIR}/olm-bundle-unpack/no-selected-bundles.txt"

export MOCK_SCENARIO=failing
run_collection "${tmpdir}/failing"
root="${ARTIFACT_DIR}/olm-bundle-unpack"
test -s "${root}/bundle-new-jobs.err"
test -s "${root}/bundle-new-pods.err"
grep -qx 'jobs query failed' "${root}/bundle-new-jobs.err"
grep -qx 'pods query failed' "${root}/bundle-new-pods.err"

grep -qx '  local timeout_seconds=10' "${script}"
grep -qx '  local max_jobs=3' "${script}"
grep -qx '  local max_pods=3' "${script}"
grep -qx '  local max_containers=3' "${script}"
echo 'OLM bundle-unpack diagnostics mock passed'
