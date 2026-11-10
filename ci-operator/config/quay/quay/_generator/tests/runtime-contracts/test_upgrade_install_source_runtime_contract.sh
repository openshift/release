#!/bin/bash
# Runtime contracts for observed source CSV version validation. The real source
# and target scripts run against a local oc mock; no cluster mutation occurs.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../../../step-registry/quay/operator-upgrade-install-source" && pwd)"
SOURCE="${ROOT}/quay-operator-upgrade-install-source-commands.sh"
TARGET="${ROOT}/../operator-upgrade-channel/quay-operator-upgrade-channel-commands.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
mkdir -p "${tmp}/bin"

cat >"${tmp}/bin/oc" <<'EOF'
#!/bin/bash
set -euo pipefail
args="$*"
if [[ "${args}" == *"lastObservedState"* ]]; then echo READY; exit 0; fi
if [[ "${args}" == *"catalogsource"*".spec.image"* ]]; then echo "${QUAY_UPGRADE_SOURCE_CATALOG_IMAGE}"; exit 0; fi
if [[ "${args}" == *"subscription"*"installedCSV"* ]]; then echo "${MOCK_CSV}"; exit 0; fi
if [[ "${args}" == *"subscription"*".spec.source"* ]]; then echo fbc-operator-catalog; exit 0; fi
if [[ "${args}" == *"subscription"*".spec.channel"* ]]; then echo stable-3.11; exit 0; fi
if [[ "${args}" == *"csv"*".status.phase"* ]]; then echo Succeeded; exit 0; fi
if [[ "${args}" == *"csv"*".spec.version"* ]]; then printf '%s' "${MOCK_VERSION}"; exit 0; fi
if [[ "${args}" == *"patch subscription"* ]]; then touch "${TARGET_MUTATION_FILE}"; exit 0; fi
exit 1
EOF
chmod +x "${tmp}/bin/oc"

run_source() {
  local name="$1" csv="$2" version="$3"
  local case_dir="${tmp}/${name}"
  mkdir -p "${case_dir}/shared" "${case_dir}/artifacts"
  (PATH="${tmp}/bin:${PATH}" SHARED_DIR="${case_dir}/shared" ARTIFACT_DIR="${case_dir}/artifacts" \
    MOCK_CSV="${csv}" MOCK_VERSION="${version}" TARGET_MUTATION_FILE="${case_dir}/target-mutated" \
    QUAY_UPGRADE_SOURCE_CATALOG_IMAGE='quay.io/redhat-user-workloads/ocp-art-tenant/art-fbc@sha256:e9a7f5414a727fbaf73721ddcb1d7b337c1fc95be681093da534f257c054010c' \
    QUAY_UPGRADE_SOURCE_CHANNEL=stable-3.11 QUAY_UPGRADE_SOURCE_CATALOG_NAME=fbc-operator-catalog \
    QUAY_UPGRADE_SOURCE_ALREADY_INSTALLED=true QUAY_UPGRADE_OPERATOR_NAMESPACE=quay-enterprise \
    QUAY_UPGRADE_CATALOG_TIMEOUT=1s bash "${SOURCE}")
}

assert_positive() {
  local name="$1" csv="$2" version="$3"
  run_source "${name}" "${csv}" "${version}"
  identity="${tmp}/${name}/shared/quay-upgrade-source-identity"
  grep -Fxq "installed_csv=${csv}" "${identity}"
  grep -Fxq "installed_version=${version}" "${identity}"
  grep -Fxq 'installed_minor=3.11' "${identity}"
}

assert_negative() {
  local name="$1" csv="$2" version="$3"
  if run_source "${name}" "${csv}" "${version}"; then
    echo "source accepted ${name}" >&2
    exit 1
  fi
  case_dir="${tmp}/${name}"
  [[ ! -e "${case_dir}/shared/quay-upgrade-source-identity" ]]
  # Target must refuse the missing verified identity before it can patch a Subscription.
  if (PATH="${tmp}/bin:${PATH}" SHARED_DIR="${case_dir}/shared" ARTIFACT_DIR="${case_dir}/artifacts" \
    MOCK_CSV="${csv}" MOCK_VERSION="${version}" TARGET_MUTATION_FILE="${case_dir}/target-mutated" \
    QUAY_UPGRADE_SOURCE_CATALOG_IMAGE='quay.io/redhat-user-workloads/ocp-art-tenant/art-fbc@sha256:e9a7f5414a727fbaf73721ddcb1d7b337c1fc95be681093da534f257c054010c' \
    QUAY_UPGRADE_TARGET_CATALOG_IMAGE='quay.io/redhat-user-workloads/ocp-art-tenant/art-fbc@sha256:fcebc181f4a760e98981aeb47dc596f601f7582b630c12e8827a8500b086171a' \
    QUAY_UPGRADE_SOURCE_CHANNEL=stable-3.11 QUAY_UPGRADE_TARGET_CHANNEL=stable-3.12 \
    QUAY_UPGRADE_SOURCE_CATALOG_NAME=fbc-operator-catalog QUAY_UPGRADE_OPERATOR_NAMESPACE=quay-enterprise \
    QUAY_UPGRADE_QUAY_NAMESPACE=quay-enterprise QUAY_UPGRADE_QUAY_REGISTRY=quay QUAY_UPGRADE_TIMEOUT=1s QUAY_UPGRADE_CATALOG_TIMEOUT=1s \
    bash "${TARGET}"); then
    echo "target accepted unverified ${name}" >&2
    exit 1
  fi
  [[ ! -e "${case_dir}/target-mutated" ]]
}

assert_positive v3119 quay-operator.v3.11.9 3.11.9
assert_positive v31113 quay-operator.v3.11.13 3.11.13
assert_negative wrong-minor quay-operator.v3.12.24 3.12.24
assert_negative malformed-version quay-operator.v3.11.13 ''
echo 'source CSV minor runtime contracts: PASS'
