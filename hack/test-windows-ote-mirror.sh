#!/bin/bash
# shellcheck disable=SC2329
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
script="${repo_root}/ci-operator/step-registry/windows/e2e/operator/test/mirror-extension/windows-e2e-operator-test-mirror-extension-commands.sh"
test_dir=$(mktemp -d)
trap 'rm -rf "${test_dir}"' EXIT

run_case() {
    local scenario="$1" source_image="$2" expected_status="$3" status=0 calls_count
    local case_dir="${test_dir}/${scenario}"
    mkdir -p "${case_dir}/tmp"
    printf '%s\n' registry.example:5000 > "${case_dir}/mirror_registry_url"
    printf '%s\n' stale-image > "${case_dir}/mirrored_extension_image"
    printf '%s\n' '{"auths": {"source.example": {"auth": "c291cmNlOnRlc3Q="}}}' > "${case_dir}/pull-secret"
    if [[ "${scenario}" != missing-auth ]]; then
        printf '%s\n' fixture:password > "${case_dir}/registry_creds"
    fi
    (
        export SHARED_DIR="${case_dir}" CLUSTER_PROFILE_DIR="${case_dir}" EXTENSION_IMAGE="${source_image}"
        export TMPDIR="${case_dir}/tmp"
        export KUBECONFIG="${case_dir}/cluster-under-test"
        export case_dir scenario source_image
        jq() {
            local arguments=() argument
            for argument in "$@"; do
                if [[ "${argument}" == /var/run/vault/mirror-registry/registry_creds ]]; then
                    argument="${case_dir}/registry_creds"
                fi
                arguments+=("${argument}")
            done
            command jq "${arguments[@]}"
        }
        oc() {
            printf '%s\n' "$*" >> "${case_dir}/calls"
            test ! -e "${case_dir}/mirrored_extension_image" || return 99
            if [[ "$1 $2" == 'registry login' ]]; then
                [[ "${KUBECONFIG}" == '' && "$3" == --to && -s "$4" ]] || return 99
                return 0
            fi
            local previous='' argument auth_file=''
            for argument in "$@"; do
                if [[ "${previous}" == -a ]]; then auth_file="${argument}"; fi
                previous="${argument}"
            done
            printf '%s\n' "${auth_file}" > "${case_dir}/auth-path"
            [[ $(stat -c %a "${auth_file}" 2>/dev/null || stat -f %Lp "${auth_file}") == 600 ]] || return 99
            [[ $(stat -c %a "$(dirname "${auth_file}")" 2>/dev/null || stat -f %Lp "$(dirname "${auth_file}")") == 700 ]] || return 99
            command jq -e '.auths["registry.example:5000"].auth == "Zml4dHVyZTpwYXNzd29yZA==" and .auths["source.example"].auth == "c291cmNlOnRlc3Q="' "${auth_file}" > /dev/null || return 99
            case "$1 $2" in
                'image mirror')
                    [[ "$3" == "${source_image}" && "$4" == registry.example:5000/pipeline:wmco-tests-extension ]] || return 99
                    [[ "${scenario}" != mirror-failure ]] || return 1
                    ;;
                'image info')
                    [[ "$3" == registry.example:5000/pipeline:wmco-tests-extension ]] || return 99
                    [[ "${scenario}" != verification-failure ]] || return 1
                    ;;
                *) return 99 ;;
            esac
        }
        sleep() { :; }
        export -f oc sleep jq
        bash "${script}"
    ) > "${case_dir}/output" 2>&1 || status=$?
    [[ "${status}" == "${expected_status}" ]]
    [[ -z $(ls -A "${case_dir}/tmp") ]]
    if [[ -f "${case_dir}/auth-path" ]]; then
        test ! -e "$(cat "${case_dir}/auth-path")"
    fi
    if [[ "${expected_status}" == 0 ]]; then
        [[ $(cat "${case_dir}/mirrored_extension_image") == registry.example:5000/pipeline:wmco-tests-extension ]]
        calls_count=$(( $(wc -l < "${case_dir}/calls") ))
        [[ "${calls_count}" == 3 ]]
        [[ $(tail -n 1 "${case_dir}/calls") == 'image info '* ]]
    else
        test ! -e "${case_dir}/mirrored_extension_image"
    fi
    if [[ "${scenario}" == mirror-failure ]]; then
        calls_count=$(( $(wc -l < "${case_dir}/calls") ))
        [[ "${calls_count}" == 7 ]]
        if grep -q '^image info ' "${case_dir}/calls"; then return 1; fi
    fi
    printf 'PASS: %s\n' "${scenario}"
}

run_case fbc-tag registry.example/ci/pipeline:wmco-tests 0
run_case ote-tag registry.example/ci/pipeline:windows-machine-config-operator-test 0
run_case fbc-digest "registry.example/ci/pipeline@sha256:$(printf 'a%.0s' {1..64})" 0
run_case ote-digest "registry.example/ci/pipeline@sha256:$(printf 'b%.0s' {1..64})" 0
run_case mirror-failure registry.example/ci/pipeline:wmco-tests 1
run_case verification-failure registry.example/ci/pipeline:windows-machine-config-operator-test 1
run_case missing-dependency '' 1
run_case missing-auth registry.example/ci/pipeline:wmco-tests 2

python3 - "${repo_root}" <<'PY'
import pathlib
import sys

import yaml

root = pathlib.Path(sys.argv[1])
registry = root / "ci-operator/step-registry"
shared = registry / "windows/e2e/operator/test/mirror-images"
assert not yaml.safe_load(next(shared.glob("*-ref.yaml")).read_text())["ref"].get("dependencies")
shared_commands = next(shared.glob("*-commands.sh")).read_text()
assert "mirrored_extension_image" not in shared_commands
buildfarm_login = 'KUBECONFIG="" oc registry login --to "${new_pull_secret}"'
assert buildfarm_login in shared_commands
assert shared_commands.index(buildfarm_login) < shared_commands.index('oc image mirror "${wmco_image_src}"')
mirror = "windows-e2e-operator-test-mirror-extension"
extension = registry / "windows/e2e/operator/test/mirror-extension"
assert yaml.safe_load(next(extension.glob("*-ref.yaml")).read_text())["ref"]["dependencies"] == [
    {"name": "EXTENSION_IMAGE", "env": "EXTENSION_IMAGE"}
]
consumers = []
legacy_consumers = []
workflows = {
    "windows-e2e-operator-test-vsphere-disconnected",
    "cucushift-installer-rehearse-vsphere-ipi-disconnected-ovn-winc",
}
for path in (root / "ci-operator/config").glob("*/*/*.yaml"):
    text = path.read_text()
    if not any(workflow in text for workflow in workflows):
        continue
    config = yaml.safe_load(text)
    for test in config.get("tests", []):
        steps = test.get("steps", {})
        refs = [step.get("ref") for step in steps.get("test", [])]
        if mirror in refs:
            consumers.append((path.name, test["as"]))
            assert "disconnected" in test["as"]
            assert refs[0] == mirror
            assert refs.index(mirror) < refs.index("openshift-tests-extension-setup-out-of-payload")
            alias = steps["dependencies"]["EXTENSION_IMAGE"]
            assert alias in config.get("base_images", {}) or any(
                image["to"] == alias for image in config.get("images", {}).get("items", [])
            )
        elif steps.get("workflow") in workflows:
            legacy_consumers.append((path.name, test["as"]))
assert len(consumers) == 2, consumers
assert legacy_consumers
for path in registry.rglob("*-chain.yaml"):
    text = path.read_text()
    if "ref: windows-e2e-operator-test-mirror-images" in text:
        assert mirror not in text, path
print(f"PASS: FBC and __ote dependency contracts; {len(legacy_consumers)} legacy consumers retain dependency-free mirroring")
PY
