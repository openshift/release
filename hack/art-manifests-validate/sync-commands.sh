#!/bin/bash
# Regenerate the embedded validator in the step-registry commands script.
set -o errexit
set -o nounset
set -o pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PY="${ROOT}/hack/art-manifests-validate/validate_art_manifests.py"
OUT="${ROOT}/ci-operator/step-registry/ocp-art/validate/art-manifests/ocp-art-validate-art-manifests-commands.sh"

py_content="$(<"${PY}")"
if [[ "${py_content}" == *$'if __name__ == "__main__":'* ]]; then
    py_content="${py_content%%if __name__ == "__main__":*}"
    py_content="${py_content%"${py_content##*[![:space:]]}"}"
fi

cat >"${OUT}" <<EOF
#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if ! python3 -c 'import yaml' >/dev/null 2>&1; then
    echo "PyYAML not found; installing..."
    if command -v microdnf >/dev/null 2>&1; then
        microdnf install -y python3-pyyaml
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y python3-pyyaml
    elif python3 -m pip --version >/dev/null 2>&1; then
        python3 -m pip install --disable-pip-version-check --no-cache-dir pyyaml
    else
        echo "ERROR: PyYAML is required and could not be installed (no microdnf, dnf, or pip)"
        exit 1
    fi
fi

RELEASE_BRANCH="\${RELEASE_BRANCH:-}"
if [[ -z "\${RELEASE_BRANCH}" && -n "\${JOB_SPEC:-}" ]]; then
    RELEASE_BRANCH="\$(echo "\${JOB_SPEC}" | jq -r '.refs.base_ref // .extra_refs[0].base_ref // empty')"
fi

if [[ -z "\${RELEASE_BRANCH}" ]]; then
    echo "ERROR: RELEASE_BRANCH is required (set explicitly or via JOB_SPEC base_ref)"
    exit 1
fi

echo "Validating ART manifests for branch \${RELEASE_BRANCH} in \${PWD}"
export ART_VALIDATE_REPO_ROOT="\${PWD}"
export ART_VALIDATE_RELEASE_BRANCH="\${RELEASE_BRANCH}"
python3 <<'PYVALIDATOR'
${py_content}
if __name__ == "__main__":
    import os
    import sys
    sys.exit(
        main(
            [
                "--repo-root",
                os.environ["ART_VALIDATE_REPO_ROOT"],
                "--release-branch",
                os.environ["ART_VALIDATE_RELEASE_BRANCH"],
            ]
        )
    )
PYVALIDATOR
EOF

chmod +x "${OUT}"
echo "Wrote ${OUT}"
