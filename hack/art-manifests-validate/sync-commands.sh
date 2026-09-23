#!/bin/bash
# Regenerate the embedded validator in the step-registry commands script.
set -o errexit
set -o nounset
set -o pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PY="${ROOT}/hack/art-manifests-validate/validate_art_manifests.py"
OUT="${ROOT}/ci-operator/step-registry/ocp-art/validate/art-manifests/ocp-art-validate-art-manifests-commands.sh"

py_content="$(sed '/^if __name__ == "__main__":/,$d' "${PY}")"
py_content="${py_content%"${py_content##*[![:space:]]}"}"
py_content="${py_content}"$'\n'

cat >"${OUT}" <<EOF
#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export HOME="\${HOME:-/tmp}"
if ! python3 -c 'import yaml' >/dev/null 2>&1; then
    echo "PyYAML not found; bootstrapping pip via ensurepip..."
    if ! python3 -m pip --version >/dev/null 2>&1; then
        python3 -m ensurepip --upgrade --user
    fi
    export PATH="\${HOME}/.local/bin:\${PATH}"
    python3 -m pip install --user --disable-pip-version-check --no-cache-dir 'pyyaml==6.0'
fi

echo "Validating ART manifests in \${PWD}"
export ART_VALIDATE_REPO_ROOT="\${PWD}"
python3 <<'PYVALIDATOR'
${py_content}
if __name__ == "__main__":
    import os
    import sys

    argv = ["--repo-root", os.environ["ART_VALIDATE_REPO_ROOT"]]
    if os.environ.get("RELEASE_BRANCH"):
        argv.extend(["--release-branch", os.environ["RELEASE_BRANCH"]])
    sys.exit(main(argv))
PYVALIDATOR
EOF

chmod +x "${OUT}"
echo "Wrote ${OUT}"
