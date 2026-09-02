#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

repository_root="${1:-.}"
repository_root="$(cd "${repository_root}" && pwd)"
policy_dir="${repository_root}/ci-operator/model-policy"
allowlist_file="${policy_dir}/authorized-paths.txt"
restricted_model_pattern='claude-(opus-5([._-][[:alnum:]][[:alnum:]._-]*)?|fable-[[:alnum:]][[:alnum:]._-]*|mythos-[[:alnum:]][[:alnum:]._-]*)([^[:alnum:]_.-]|$)'
scan_paths=(
  "ci-operator/step-registry"
  "ci-operator/jobs"
)

if [[ ! -f "${allowlist_file}" ]]; then
  echo "ERROR: Restricted model allowlist not found: ${allowlist_file}" >&2
  exit 1
fi

work_dir="$(mktemp -d)"
trap 'rm -rf "${work_dir}"' EXIT
normalized_allowlist="${work_dir}/authorized-paths.txt"
: > "${normalized_allowlist}"

allowlist_error=false
while IFS= read -r entry || [[ -n "${entry}" ]]; do
  # Ignore comments and empty lines, including lines containing only whitespace.
  entry="${entry#"${entry%%[![:space:]]*}"}"
  entry="${entry%"${entry##*[![:space:]]}"}"
  if [[ -z "${entry}" || "${entry}" == \#* ]]; then
    continue
  fi

  case "${entry}" in
    ci-operator/step-registry/*|ci-operator/jobs/*) ;;
    *)
      echo "ERROR: Allowlist entry must be an exact path under a scanned directory: ${entry}" >&2
      allowlist_error=true
      continue
      ;;
  esac

  if [[ ! -f "${repository_root}/${entry}" ]]; then
    echo "ERROR: Allowlist entry does not name a regular file: ${entry}" >&2
    allowlist_error=true
    continue
  fi

  if grep -Fqx "${entry}" "${normalized_allowlist}"; then
    echo "ERROR: Duplicate restricted model allowlist entry: ${entry}" >&2
    allowlist_error=true
    continue
  fi

  printf '%s\n' "${entry}" >> "${normalized_allowlist}"
done < "${allowlist_file}"

if [[ "${allowlist_error}" == true ]]; then
  exit 1
fi

unauthorized=false
match_output="${work_dir}/matches"
: > "${match_output}"
absolute_scan_paths=()
for scan_path in "${scan_paths[@]}"; do
  absolute_scan_path="${repository_root}/${scan_path}"
  if [[ ! -d "${absolute_scan_path}" ]]; then
    echo "ERROR: Model policy scan directory not found: ${scan_path}" >&2
    exit 1
  fi
  absolute_scan_paths+=("${absolute_scan_path}")
done

if LC_ALL=C grep -rIEn "${restricted_model_pattern}" "${absolute_scan_paths[@]}" > "${match_output}"; then
  grep_status=0
else
  grep_status=$?
fi

if [[ "${grep_status}" -eq 0 ]]; then
  cut -d: -f1 "${match_output}" | LC_ALL=C sort -u > "${work_dir}/matching-paths"
elif [[ "${grep_status}" -eq 1 ]]; then
  : > "${work_dir}/matching-paths"
else
  echo "ERROR: Failed to scan for restricted model references" >&2
  exit "${grep_status}"
fi

while IFS= read -r candidate; do
  relative_path="${candidate#"${repository_root}/"}"
  if grep -Fqx "${relative_path}" "${normalized_allowlist}"; then
    continue
  fi

  unauthorized=true
  echo "ERROR: Unauthorized restricted model reference in ${relative_path}:" >&2
  while IFS= read -r match; do
    case "${match}" in
      "${candidate}":*) printf '  %s\n' "${match#"${repository_root}/"}" >&2 ;;
    esac
  done < "${match_output}"
done < "${work_dir}/matching-paths"

if [[ "${unauthorized}" == true ]]; then
  cat >&2 <<EOF
ERROR: Restricted Claude models may only be used from explicitly
ERROR: authorized paths. Add the exact path to
ERROR: ci-operator/model-policy/authorized-paths.txt with approval from a model
ERROR: policy owner.
EOF
  exit 1
fi

echo "Restricted agent model policy check: PASS"
