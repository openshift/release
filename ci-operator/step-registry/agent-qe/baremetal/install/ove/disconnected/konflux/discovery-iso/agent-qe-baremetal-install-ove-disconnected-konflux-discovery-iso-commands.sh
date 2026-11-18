#!/bin/bash

set -o errtrace
set -o errexit
set -o pipefail
set -o nounset

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM ERR

[ -z "${AUX_HOST}" ] && { echo "\$AUX_HOST is not filled. Failing."; exit 1; }
for required in \
  "${SHARED_DIR}/assisted-service-url" \
  "${SHARED_DIR}/assisted-openshift-version" \
  "${SHARED_DIR}/assisted-cpu-arch" \
  "${SHARED_DIR}/agent-config.yaml" \
  "${SHARED_DIR}/cluster_name" \
  "${CLUSTER_PROFILE_DIR}/pull-secret" \
  "${CLUSTER_PROFILE_DIR}/ssh-publickey" \
  "${CLUSTER_PROFILE_DIR}/ove_iso_storage_host"
do
  [ -f "${required}" ] || { echo "Missing ${required}."; exit 1; }
done
if [ "${DISCONNECTED}" == "true" ]; then
  [ -f "${SHARED_DIR}/proxy-conf.sh" ] || { echo "Proxy conf file is not found. Failing."; exit 1; }
fi

SSHOPTS=(-o 'ConnectTimeout=5'
  -o 'StrictHostKeyChecking=no'
  -o 'UserKnownHostsFile=/dev/null'
  -o 'TCPKeepAlive=yes'
  -o 'ServerAliveInterval=30'
  -o LogLevel=ERROR
  -i "${CLUSTER_PROFILE_DIR}/ssh-key")

CLUSTER_NAME=$(<"${SHARED_DIR}/cluster_name")
API_NAME="${CLUSTER_NAME:0:54}"
OPENSHIFT_VERSION=$(<"${SHARED_DIR}/assisted-openshift-version")
CPU_ARCH=$(<"${SHARED_DIR}/assisted-cpu-arch")
OVE_ISO_STORAGE_HOST=$(<"${CLUSTER_PROFILE_DIR}/ove_iso_storage_host")
WORK_DIR="/var/lib/assisted/${CLUSTER_NAME}"
RENDEZVOUS_IP=$(yq e -r '.rendezvousIP // ""' "${SHARED_DIR}/agent-config.yaml")
NTP_SOURCES=$(yq e -r '(.additionalNTPSources // []) | join(",")' "${SHARED_DIR}/agent-config.yaml")

build_static_network() {
  local config="$1"
  local count has i yaml map
  local -a items=()
  count=$(yq e '.hosts // [] | length' "${config}")
  if [ "${count}" -eq 0 ]; then
    echo '[]'
    return
  fi
  for ((i=0; i<count; i++)); do
    has=$(yq e ".hosts[${i}] | has(\"networkConfig\")" "${config}")
    [ "${has}" = "true" ] || continue
    yaml=$(yq e -o=yaml ".hosts[${i}].networkConfig" "${config}")
    map=$(yq e -o=json "[(.hosts[${i}].interfaces // [])[] | {\"mac_address\": .macAddress, \"logical_nic_name\": .name}]" "${config}")
    items+=("$(jq -nc --arg network_yaml "${yaml}" --argjson mac_interface_map "${map}" '{network_yaml:$network_yaml, mac_interface_map:$mac_interface_map}')")
  done
  if [ "${#items[@]}" -eq 0 ]; then
    echo '[]'
    return
  fi
  printf '%s\n' "${items[@]}" | jq -sc '.'
}

STATIC_NETWORK_CONFIG='[]'
if [ "${PATCH_STATIC_NETWORK}" == "true" ]; then
  STATIC_NETWORK_CONFIG=$(build_static_network "${SHARED_DIR}/agent-config.yaml")
fi

PROXY_JSON='null'
if [ "${DISCONNECTED}" == "true" ]; then
  # shellcheck disable=SC1091
  source "${SHARED_DIR}/proxy-conf.sh"
  PROXY_JSON=$(jq -nc \
    --arg http_proxy "${HTTP_PROXY:-}" \
    --arg https_proxy "${HTTPS_PROXY:-}" \
    --arg no_proxy "${NO_PROXY:-}" \
    '{http_proxy:$http_proxy, https_proxy:$https_proxy, no_proxy:$no_proxy} | with_entries(select(.value != ""))')
fi

SSH_AUTHORIZED_KEY=$(tr -d '\r\n' < "${CLUSTER_PROFILE_DIR}/ssh-publickey")
[ -n "${SSH_AUTHORIZED_KEY}" ] || { echo "Cluster SSH public key is empty."; exit 1; }

WORKDIR_LOCAL=$(mktemp -d)
chmod 700 "${WORKDIR_LOCAL}"
cleanup_local() {
  rm -rf "${WORKDIR_LOCAL}"
}
trap 'cleanup_local' EXIT

PULL_SECRET_FILE="${WORKDIR_LOCAL}/pull-secret"
python3 -c 'import pathlib,sys; pathlib.Path(sys.argv[2]).write_text(pathlib.Path(sys.argv[1]).read_text().strip())' \
  "${CLUSTER_PROFILE_DIR}/pull-secret" "${PULL_SECRET_FILE}"
chmod 600 "${PULL_SECRET_FILE}"
jq -e . "${PULL_SECRET_FILE}" >/dev/null

jq -nc \
  --arg name "${API_NAME}" \
  --arg openshift_version "${OPENSHIFT_VERSION}" \
  '{name:$name, openshift_version:$openshift_version}' > "${WORKDIR_LOCAL}/cluster.json"

jq -nc \
  --arg name "${API_NAME}" \
  --rawfile pull_secret "${PULL_SECRET_FILE}" \
  --arg ssh_authorized_key "${SSH_AUTHORIZED_KEY}" \
  --arg openshift_version "${OPENSHIFT_VERSION}" \
  --arg cpu_architecture "${CPU_ARCH}" \
  --arg rendezvous_ip "${RENDEZVOUS_IP}" \
  --arg additional_ntp_sources "${NTP_SOURCES}" \
  --argjson proxy "${PROXY_JSON}" \
  --argjson static_network_config "${STATIC_NETWORK_CONFIG}" \
  '{
    name: $name,
    pull_secret: $pull_secret,
    ssh_authorized_key: $ssh_authorized_key,
    image_type: "disconnected-iso",
    openshift_version: $openshift_version,
    cpu_architecture: $cpu_architecture
  }
  + (if $rendezvous_ip != "" then {rendezvous_ip: $rendezvous_ip} else {} end)
  + (if $additional_ntp_sources != "" then {additional_ntp_sources: $additional_ntp_sources} else {} end)
  + (if $proxy != null and $proxy != {} then {proxy: $proxy} else {} end)
  + (if ($static_network_config | length) > 0 then {static_network_config: $static_network_config} else {} end)' \
  > "${WORKDIR_LOCAL}/infraenv.json"
chmod 600 "${WORKDIR_LOCAL}/cluster.json" "${WORKDIR_LOCAL}/infraenv.json"

# shellcheck disable=SC2029
scp "${SSHOPTS[@]}" "${WORKDIR_LOCAL}/cluster.json" "${WORKDIR_LOCAL}/infraenv.json" "root@${AUX_HOST}:${WORK_DIR}/"
# shellcheck disable=SC2029
ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" "chmod 600 $(printf '%q' "${WORK_DIR}/cluster.json") $(printf '%q' "${WORK_DIR}/infraenv.json")"

timeout -s 9 150m ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" \
  "WORK_DIR=$(printf '%q' "${WORK_DIR}") CLUSTER_NAME=$(printf '%q' "${CLUSTER_NAME}") OVE_ISO_STORAGE_HOST=$(printf '%q' "${OVE_ISO_STORAGE_HOST}") bash -s" <<'EOF'
set -o errexit
set -o pipefail
set -o nounset

# shellcheck disable=SC1091
source "${WORK_DIR}/runtime.env"
API="http://127.0.0.1:${SERVICE_PORT}/api/assisted-install"
rm -f "${WORK_DIR}/discovery.iso"

redact_failure() {
  local body="$1"
  local code="$2"
  python3 - "$body" "$code" <<'PY'
import pathlib, re, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text(errors="replace") if path.is_file() else ""
text = re.sub(r'("(?:pull_secret|ssh_authorized_key)"\s*:\s*")(?:\\.|[^"\\])*(")', r'\1<redacted>\2', text)
text = re.sub(r'((?:https?|http)://)[^@\s\"]+:[^@\s\"]+@', r'\1<redacted>@', text)
print(f"assisted-service returned HTTP {sys.argv[2]}", file=sys.stderr)
print(text[:2000], file=sys.stderr)
PY
}

api_json() {
  local method="$1"
  local path="$2"
  local expected="$3"
  local body="${4:-}"
  local out="$5"
  local code
  if [ -n "${body}" ]; then
    code=$(curl -sS -o "${out}" -w '%{http_code}' -X "${method}" -H 'Content-Type: application/json' --data @"${body}" "${API}${path}" || true)
  else
    code=$(curl -sS -o "${out}" -w '%{http_code}' -X "${method}" "${API}${path}" || true)
  fi
  if [ "${code}" != "${expected}" ]; then
    redact_failure "${out}" "${code:-000}"
    rm -f "${out}"
    [ -n "${body}" ] && rm -f "${body}"
    exit 1
  fi
}

api_json POST /v2/clusters/disconnected 201 "${WORK_DIR}/cluster.json" "${WORK_DIR}/cluster-response.json"
python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "${WORK_DIR}/cluster-response.json" > "${WORK_DIR}/cluster-id"
rm -f "${WORK_DIR}/cluster.json" "${WORK_DIR}/cluster-response.json"

python3 - "${WORK_DIR}" <<'PY'
import json, pathlib, sys
work = pathlib.Path(sys.argv[1])
body = json.loads((work / "infraenv.json").read_text())
body["cluster_id"] = (work / "cluster-id").read_text().strip()
(work / "infraenv.json").write_text(json.dumps(body))
PY

api_json POST /v2/infra-envs 201 "${WORK_DIR}/infraenv.json" "${WORK_DIR}/infraenv-response.json"
python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "${WORK_DIR}/infraenv-response.json" > "${WORK_DIR}/infra-env-id"
rm -f "${WORK_DIR}/infraenv.json" "${WORK_DIR}/infraenv-response.json"
INFRA_ENV_ID=$(<"${WORK_DIR}/infra-env-id")

image_url=""
for _ in $(seq 1 10); do
  code=$(curl -sS -o "${WORK_DIR}/image-url.json" -w '%{http_code}' "${API}/v2/infra-envs/${INFRA_ENV_ID}/downloads/image-url" || true)
  if [ "${code}" = "200" ]; then
    image_url=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["url"])' "${WORK_DIR}/image-url.json")
    break
  fi
  rm -f "${WORK_DIR}/image-url.json"
  sleep 15
done
rm -f "${WORK_DIR}/image-url.json"
[ -n "${image_url}" ] || { echo "assisted-service did not return a discovery image URL."; exit 1; }
case "${image_url}" in
  http://*|https://*) ;;
  *)
    echo "Discovery image URL is not an HTTP URL."
    exit 1
    ;;
esac

downloaded=false
for _ in $(seq 1 5); do
  rm -f "${WORK_DIR}/discovery.iso"
  if curl -fL --max-time 5400 -o "${WORK_DIR}/discovery.iso" "${image_url}"; then
    downloaded=true
    break
  fi
  sleep 20
done
unset image_url
[ "${downloaded}" = "true" ] || { echo "Discovery ISO download failed."; exit 1; }
[ -s "${WORK_DIR}/discovery.iso" ] || { echo "Downloaded discovery ISO is empty."; exit 1; }

local_size=$(stat -c '%s' "${WORK_DIR}/discovery.iso")
CONTAINER_NAME="haproxy-${CLUSTER_NAME}"
nsenter -n -t "$(podman inspect -f '{{ .State.Pid }}' "${CONTAINER_NAME}")" \
  ssh -o StrictHostKeyChecking=no root@"${OVE_ISO_STORAGE_HOST}" \
  "cat > /var/mnt/data-storage/html/${CLUSTER_NAME}.discovery.iso && chmod 644 /var/mnt/data-storage/html/${CLUSTER_NAME}.discovery.iso" \
  < "${WORK_DIR}/discovery.iso"
remote_size=$(nsenter -n -t "$(podman inspect -f '{{ .State.Pid }}' "${CONTAINER_NAME}")" \
  ssh -o StrictHostKeyChecking=no root@"${OVE_ISO_STORAGE_HOST}" \
  "stat -c '%s' /var/mnt/data-storage/html/${CLUSTER_NAME}.discovery.iso")
[ "${local_size}" = "${remote_size}" ] || { echo "Discovery ISO copy to the storage host is incomplete."; exit 1; }
rm -f "${WORK_DIR}/discovery.iso"
echo "Published discovery ISO (${local_size} bytes)."
EOF

# shellcheck disable=SC2029
scp "${SSHOPTS[@]}" \
  "root@${AUX_HOST}:${WORK_DIR}/cluster-id" \
  "root@${AUX_HOST}:${WORK_DIR}/infra-env-id" \
  "${SHARED_DIR}/"
mv "${SHARED_DIR}/cluster-id" "${SHARED_DIR}/assisted-cluster-id"
mv "${SHARED_DIR}/infra-env-id" "${SHARED_DIR}/assisted-infra-env-id"
echo "http://${OVE_ISO_STORAGE_HOST}/${CLUSTER_NAME}.discovery.iso" > "${SHARED_DIR}/discovery-iso-url"
echo "Discovery ISO URL is $(<"${SHARED_DIR}/discovery-iso-url")"
