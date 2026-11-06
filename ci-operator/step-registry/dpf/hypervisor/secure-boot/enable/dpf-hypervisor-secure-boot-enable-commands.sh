#!/bin/bash
set +x
set -euo pipefail

# Publish only known messages. Never pass through raw SSH/Redfish diagnostics,
# sourced inventory output, or BMC addresses to public logs or artifacts.
filter_secure_boot_output() {
  sed -u -n -E \
    -e '/^(Preparing Secure Boot helper|Loading Secure Boot worker inventory|Applying and validating Secure Boot state)\.$/p' \
    -e '/^Prechecking Secure Boot state for [1-9][0-9]* worker\(s\)$/p' \
    -e '/^Worker [1-9][0-9]* already has Secure Boot (enable|disable) for its current boot; skipping change and reboot$/p' \
    -e '/^Worker [1-9][0-9]* is configured for Secure Boot (enable|disable) but current boot is (enabled|disabled|unknown); skipping PATCH$/p' \
    -e '/^Worker [1-9][0-9]* Secure Boot is configured as (enabled|disabled|unknown) \(current boot (enabled|disabled|unknown)\); will set (enable|disable)$/p' \
    -e 's/^Secure Boot (enable|disable) setting accepted for worker ([1-9][0-9]*) \(.*\)$/Secure Boot \1 setting accepted for worker \2/p' \
    -e 's/^ForceRestart requested for worker ([1-9][0-9]*) \(.*\)$/ForceRestart requested for worker \1/p' \
    -e '/^Worker [1-9][0-9]* ready: SecureBootCurrentBoot=(enabled|disabled)$/p' \
    -e '/^Worker [1-9][0-9]* pending \(SecureBootCurrentBoot=(enabled|disabled|unknown|unreachable)\)$/p' \
    -e '/^ERROR: Secure Boot precheck failed for worker [1-9][0-9]*$/p' \
    -e '/^ERROR: BMC rejected the (Secure Boot change|reboot request) for worker [1-9][0-9]*$/p' \
    -e '/^ERROR: Lab is paused; Secure Boot change not attempted\.$/p' \
    -e '/^ERROR: Worker inventory env\.user is not readable\.$/p' \
    -e '/^ERROR: Secure Boot helper clone failed\.$/p' \
    -e '/^ERROR: (Worker [1-9][0-9]* did not reach|Not all workers reached) SecureBootCurrentBoot=(enabled|disabled) within [1-9][0-9]* minutes$/p'
}

for marker in skip-work-steps skip-nno-precompiled; do
  if [[ -f "${SHARED_DIR}/${marker}" ]]; then
    echo "Skipping Secure Boot transition: ${marker} is present."
    exit 0
  fi
done

[[ -z "${WORKER_SECURE_BOOT_TIMEOUT_MINUTES}" || "${WORKER_SECURE_BOOT_TIMEOUT_MINUTES}" =~ ^([1-9]|[12][0-9]|30)$ ]] || {
  echo "WORKER_SECURE_BOOT_TIMEOUT_MINUTES must be empty or an integer from 1 to 30" >&2; exit 1;
}

cluster_name="$(cat "${CLUSTER_PROFILE_DIR}/cluster-name")"
remote_host="$(cat "${CLUSTER_PROFILE_DIR}/remote-host")"
[[ "${cluster_name}" =~ ^[a-zA-Z0-9._-]+$ && "${cluster_name}" != *..* ]] || {
  echo "Invalid cluster name" >&2; exit 1;
}
umask 077
key_file="$(mktemp)"
trap 'rm -f "${key_file}"' EXIT
base64 -d < "${CLUSTER_PROFILE_DIR}/private-key" > "${key_file}"
printf '\n' >> "${key_file}"
ssh_opts=(-q -i "${key_file}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
  -o ConnectTimeout=30 -o ServerAliveInterval=10 -o ServerAliveCountMax=3 -o BatchMode=yes)
mkdir -p "${ARTIFACT_DIR}"

state="${WORKER_SECURE_BOOT_STATE}"
[[ "${state}" == enable || "${state}" == disable ]] || {
  echo "WORKER_SECURE_BOOT_STATE must be enable or disable" >&2; exit 1;
}
printf -v command '%q ' bash -s -- "${cluster_name}" "${OPENSHIFT_DPF_BRANCH}" "${state}" \
  "${WORKER_SECURE_BOOT_TIMEOUT_MINUTES}" "${REDFISH_INSECURE}" "${REDFISH_CA_BUNDLE}"
# pipefail preserves SSH failures even when filtering produces no output.
status=0
ssh "${ssh_opts[@]}" "root@${remote_host}" "${command}" <<'REMOTE' 2>&1 | filter_secure_boot_output | tee "${ARTIFACT_DIR}/secure-boot-${state}.log" || status=$?
set +x
set -euo pipefail
test ! -f "/root/$1/pause" || { echo 'ERROR: Lab is paused; Secure Boot change not attempted.'; exit 1; }
env_file="/root/$1/ci/env/env.user_$1"
test -r "${env_file}" || { echo 'ERROR: Worker inventory env.user is not readable.'; exit 1; }
umask 077
work_dir="$(mktemp -d)"
trap 'rm -rf "${work_dir}"' EXIT
echo 'Preparing Secure Boot helper.'
git clone --quiet --depth 1 --branch "$2" \
  https://github.com/rh-ecosystem-edge/openshift-dpf.git "${work_dir}/openshift-dpf" || {
  clone_status=$?
  echo 'ERROR: Secure Boot helper clone failed.'
  exit "${clone_status}"
}
cd "${work_dir}/openshift-dpf"

# Load the lab's existing worker inventory directly. The standalone helper
# consumes worker/BMC settings without generating the installation .env.
echo 'Loading Secure Boot worker inventory.'
set -a
source "${env_file}"
set +x
set +a
export ENV_FILE=/dev/null
[[ -z "$5" ]] || export REDFISH_INSECURE="$5"
[[ -z "$6" ]] || export REDFISH_CA_BUNDLE="$6"
args=(all "$3")
[[ -z "$4" ]] || args+=("$4")
echo 'Applying and validating Secure Boot state.'
bash "${work_dir}/openshift-dpf/scripts/worker-secure-boot.sh" "${args[@]}"
REMOTE

if (( status != 0 )); then
  printf 'ERROR: Secure Boot %s failed (exit status %s); raw diagnostics suppressed.\n' "${state}" "${status}" \
    | tee -a "${ARTIFACT_DIR}/secure-boot-${state}.log" >&2
  exit "${status}"
fi
printf 'Secure Boot %s completed and validated for all workers.\n' "${state}" \
  | tee -a "${ARTIFACT_DIR}/secure-boot-${state}.log"
