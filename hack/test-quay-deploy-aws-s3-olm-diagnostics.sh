#!/usr/bin/env bash
# Verifies that warning-only stderr from successful JSON queries does not
# prevent OLM bundle-unpack diagnostics from collecting events and logs.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${repo_root}/ci-operator/step-registry/quay/deploy-aws-s3/quay-deploy-aws-s3-commands.sh"
tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

mkdir -p "${tmpdir}/bin" "${tmpdir}/artifacts"
cat > "${tmpdir}/bin/oc" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case " $* " in
  *" get catalogsource quay-operator -o jsonpath="*) printf 'catalogsource-uid\n' ;;
  *" get catalogsource quay-operator -o yaml "*) printf 'kind: CatalogSource\n' ;;
  *" get configmap -o json "*)
    printf '%s\n' '{"items":[{"metadata":{"name":"bundle-ref","creationTimestamp":"2026-01-01T00:00:00Z","ownerReferences":[{"kind":"CatalogSource","name":"quay-operator","uid":"catalogsource-uid"}]}}]}'
    printf 'Warning: configmap query succeeded with a warning\n' >&2
    ;;
  *" get jobs "*)
    printf '%s\n' '{"items":[{"metadata":{"name":"bundle-unpack-hash"}}]}'
    printf 'Warning: jobs query succeeded with a warning\n' >&2
    ;;
  *" get pods "*)
    printf '%s\n' '{"items":[{"metadata":{"name":"bundle-unpack-pod"},"spec":{"initContainers":[{"name":"init"}],"containers":[{"name":"bundle"}]}}]}'
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
ARTIFACT_DIR="${tmpdir}/artifacts"
export QUAY_OPERATOR_SOURCE="quay-operator"
archive_olm_bundle_unpack_diagnostics

root="${ARTIFACT_DIR}/olm-bundle-unpack"
jq -e '.items[0].metadata.name == "bundle-unpack-hash"' "${root}/bundle-ref-jobs.json" >/dev/null
jq -e '.items[0].metadata.name == "bundle-unpack-pod"' "${root}/bundle-ref-pods.json" >/dev/null
grep -qx 'Warning: configmap query succeeded with a warning' "${root}/catalog-configmaps.err"
grep -qx 'Warning: jobs query succeeded with a warning' "${root}/bundle-ref-jobs.err"
grep -qx 'Warning: pods query succeeded with a warning' "${root}/bundle-ref-pods.err"
grep -q -- '-c init ' "${root}/bundle-unpack-pod_init.log"
grep -q -- '-c bundle ' "${root}/bundle-unpack-pod_bundle.log"
test -s "${root}/bundle-ref-job-events.txt"
test -s "${root}/bundle-unpack-pod_events.txt"

echo 'OLM bundle-unpack warning handling mock passed'
