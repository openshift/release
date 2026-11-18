#!/bin/bash
set -euo pipefail

function verify_extension_archive() {
  local archive="$1" binary="$2" elf_magic elf_class elf_data elf_machine elf_type
  local expected_data expected_machine

  gzip -t "${archive}" || return 1
  gzip -dc "${archive}" > "${binary}" || return 1
  elf_magic=$(od -An -tx1 -N4 "${binary}" | tr -d '[:space:]')
  if [[ "${elf_magic}" != 7f454c46 ]]; then
    echo 'ERROR: gunzip did not produce a raw ELF executable (a tar archive is invalid).'
    return 1
  fi
  case "$(uname -m)" in
    x86_64) expected_data=1; expected_machine=62 ;;
    aarch64) expected_data=1; expected_machine=183 ;;
    ppc64le) expected_data=1; expected_machine=21 ;;
    s390x) expected_data=2; expected_machine=22 ;;
    *) echo 'ERROR: unsupported runner architecture'; return 1 ;;
  esac
  elf_class=$(od -An -tu1 -j4 -N1 "${binary}" | tr -d '[:space:]')
  elf_data=$(od -An -tu1 -j5 -N1 "${binary}" | tr -d '[:space:]')
  elf_machine=$(od -An -tu2 -j18 -N2 "${binary}" | tr -d '[:space:]')
  elf_type=$(od -An -tu2 -j16 -N2 "${binary}" | tr -d '[:space:]')
  if [[ "${elf_class}" != 2 || "${elf_data}" != "${expected_data}" || "${elf_machine}" != "${expected_machine}" ]]; then
    echo 'ERROR: extension ELF architecture does not match the test runner.'
    return 1
  fi
  if [[ "${elf_type}" != 2 && "${elf_type}" != 3 ]]; then
    echo 'ERROR: extension ELF is not an executable or PIE.'
    return 1
  fi
  chmod u+x "${binary}"
  echo 'PASS: gzip CRC, raw ELF executable and host architecture.'
}

function list_extension_tests() {
  local binary="$1" source="$2" output="$3"
  timeout 60s "${binary}" list tests -o json > "${output}" || return 1
  jq -e --slurp --arg source "${source}" '
    length == 1 and (.[0] | type == "array" and length > 0 and
    all(.[]; .source == $source and (.name | type == "string" and length > 0)))
  ' "${output}" > /dev/null || return 1
  echo "PASS: extension lists $(jq length "${output}") tests with the expected source."
}

function cleanup_extension() {
  if [[ -n "${router_extension_dir:-}" ]]; then
    rm -rf "${router_extension_dir}"
  fi
}

function main() {
  export KUBECONFIG="${SHARED_DIR:?}/kubeconfig"
  : "${ARTIFACT_DIR:?}" "${RELEASE_IMAGE_LATEST:?}" "${VALIDATION_COMPONENT:?}" "${EXTENSION_BINARY_PATH:?}" "${EXTENSION_SOURCE:?}"
  local component_image component_digest namespace pod container
  router_extension_dir=$(mktemp -d /tmp/test-extension.XXXXXX)
  trap cleanup_extension EXIT
  mkdir -p "${ARTIFACT_DIR}"
  printf '%s\n' '<testsuite name="test-extension" tests="1" errors="1"><testcase name="payload-extension-packaging-and-discovery"><error message="Extension validation did not complete; see step logs"/></testcase></testsuite>' > "${ARTIFACT_DIR}/junit_test_extension.xml"

  component_image=$(oc --request-timeout=60s adm release info "${RELEASE_IMAGE_LATEST}" --registry-config=/var/run/registry-pull-credentials/.dockerconfigjson --image-for="${VALIDATION_COMPONENT}")
  [[ "${component_image}" == *@sha256:* ]]
  component_digest="${component_image##*@}"
  printf '%s\n' "${component_image}" > "${ARTIFACT_DIR}/component-image.txt"
  oc --request-timeout=60s get pods --all-namespaces -o json | jq --arg digest "${component_digest}" '[
    .items[] | .metadata as $metadata | .status.containerStatuses[]? |
    select(.ready and (.imageID | endswith("@" + $digest))) |
    {namespace: $metadata.namespace, pod: $metadata.name, container: .name, imageID: .imageID}
  ]' > "${ARTIFACT_DIR}/deployment.json"
  jq -e 'length > 0' "${ARTIFACT_DIR}/deployment.json" > /dev/null
  read -r namespace pod container < <(jq -r '.[0] | [.namespace, .pod, .container] | @tsv' "${ARTIFACT_DIR}/deployment.json")
  oc --request-timeout=60s -n "${namespace}" exec "${pod}" -c "${container}" -- cat "${EXTENSION_BINARY_PATH}" > "${router_extension_dir}/extension.gz"
  verify_extension_archive "${router_extension_dir}/extension.gz" "${router_extension_dir}/extension" | tee "${ARTIFACT_DIR}/format-check.txt"
  list_extension_tests "${router_extension_dir}/extension" "${EXTENSION_SOURCE}" "${ARTIFACT_DIR}/extension-tests.json" | tee "${ARTIFACT_DIR}/discovery-check.txt"
  printf '%s\n' '<testsuite name="test-extension" tests="1" errors="0" failures="0"><testcase name="payload-extension-packaging-and-discovery"/></testsuite>' > "${ARTIFACT_DIR}/junit_test_extension.xml"
}

# CI evaluates command text with bash -c, where BASH_SOURCE can be unset.
if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
  main "$@"
fi
