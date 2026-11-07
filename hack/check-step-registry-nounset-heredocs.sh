#!/bin/bash
# Detect set -u unsafe variable expansion inside unquoted heredocs.
#
# Failure mode: an unquoted heredoc (<<EOF) expands ${VAR} in the outer shell.
# With nounset (-u), referencing a variable that only exists in a generated
# container env block (or inner script) aborts the step before oc apply runs.
#
# Example bug: "core@${VMI_IP}" in a pod command block while outer shell only
# defines vmi_ip; fix: "core@\${VMI_IP}" or "core@${vmi_ip}".

set -o errexit
set -o nounset
set -o pipefail

ROOT="${1:-.}"
shopt -s globstar nullglob

COMMON_ENV_VARS='^(PROW_|SHARED_DIR|ARTIFACT_DIR|KUBECONFIG|RELEASE_|CLUSTER_|HYPERSHIFT_|LOCALNET_|ATTACH_|ETCD_|CONTROL_|INFRA_|ENABLE_|DISCONNECTED|EXTRA_ARGS|IP_STACK|MCE|HCP_|OVN_|NODE|NAD_|SUBNET|IPECHO_|NESTED_|GPU_|PULL_|ICSP_|RENDER_|HO_|CAPI_|OLM_|PAYLOAD|RUN_|AWS_|AZURE_|GCP_|OPENSTACK_|SSHOPTS|SSH_|IP|CCS_|REDHAT_|CONTAINER_|WORKDIR|HOME|PATH|OSTYPE|UID|EUID|PPID|SECONDS|RANDOM|LINENO|FUNCNAME|BASH_)'

failures=0

check_file() {
  local file="$1"
  grep -Eq 'set[^[:space:]]*u|set -o nounset|nounset' "${file}" || return 0

  python3 - "${file}" <<'PY'
import re
import sys

path = sys.argv[1]
text = open(path, encoding="utf-8", errors="replace").read()

# Unquoted heredoc: <<WORD or <<-WORD (not <<'WORD' or <<WORD with quotes)
heredoc_start = re.compile(r'<<-?\s*(?!["\'])([A-Za-z0-9_]+)\b')

common_env = re.compile(
    r"^(PROW_|SHARED_DIR|ARTIFACT_DIR|KUBECONFIG|RELEASE_|CLUSTER_|HYPERSHIFT_|"
    r"LOCALNET_|ATTACH_|ETCD_|CONTROL_|INFRA_|ENABLE_|DISCONNECTED|EXTRA_ARGS|"
    r"IP_STACK|MCE|HCP_|OVN_|NAD_|SUBNET|IPECHO_|NESTED_|GPU_|PULL_|ICSP_|"
    r"RENDER_|HO_|CAPI_|OLM_|PAYLOAD|RUN_|AWS_|AZURE_|GCP_|OPENSTACK_|SSHOPTS|"
    r"SSH_|CCS_|REDHAT_|CONTAINER_|WORKDIR|HOME|PATH|OSTYPE|UID|EUID|PPID|"
    r"SECONDS|RANDOM|LINENO|FUNCNAME|BASH_)"
)

outer_assign = re.compile(
    r"^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=",
    re.MULTILINE,
)
outer_params = re.compile(r"^\s*local\s+([A-Za-z_][A-Za-z0-9_]*)=", re.MULTILINE)

assigned = set(outer_assign.findall(text))
assigned.update(outer_params.findall(text))

pos = 0
issues = []

while True:
    m = heredoc_start.search(text, pos)
    if not m:
        break
    delim = m.group(1)
    body_start = m.end()
    end_pat = re.compile(rf"^\s*{re.escape(delim)}\s*$", re.MULTILINE)
    end = end_pat.search(text, body_start)
    if not end:
        pos = body_start
        continue
    body = text[body_start : end.start()]
    pos = end.end()

    # Container env vars declared in this heredoc block
    container_env = set(re.findall(r"^\s*-\s*name:\s*([A-Za-z_][A-Za-z0-9_]*)\s*$", body, re.MULTILINE))

    for line_no, line in enumerate(body.splitlines(), start=text.count("\n", 0, body_start) + 1):
        # Skip YAML/env value lines that intentionally set container env from outer shell
        if re.search(r"^\s*value:\s*", line):
            continue
        for var in re.findall(r"(?<![\\$])\$\{([A-Za-z_][A-Za-z0-9_]*)\}", line):
            if var in assigned or common_env.match(var):
                continue
            if var in container_env:
                issues.append((line_no, var, line.rstrip()))

for line_no, var, line in issues:
    print(f"{path}:{line_no}: suspicious ${{{var}}} in unquoted heredoc (nounset): {line}")

sys.exit(1 if issues else 0)
PY
  local rc=$?
  if [[ ${rc} -ne 0 ]]; then
    failures=$((failures + 1))
  fi
}

while IFS= read -r -d '' file; do
  check_file "${file}"
done < <(find "${ROOT}/ci-operator/step-registry" -name '*-commands.sh' -print0)

if [[ ${failures} -gt 0 ]]; then
  echo
  echo "${failures} file(s) with possible nounset/heredoc issues (review required; some may be false positives)."
  exit 1
fi

echo "No suspicious nounset/heredoc patterns found under ci-operator/step-registry."
