#!/bin/bash
set +x
set -euo pipefail
umask 077

cleanup() {
  rm -rf -- "${TEMP_DIR}"
}

validate_inputs() {
  : "${CLUSTER_NAME:?CLUSTER_NAME is required}"
  : "${SEED_SPOKE_CLUSTER:?SEED_SPOKE_CLUSTER is required}"
  : "${VERSION:?VERSION is required}"
  : "${MIRROR_REGISTRY:?MIRROR_REGISTRY is required}"
  : "${ZTP_GIT_REPO:?ZTP_GIT_REPO is required}"
  : "${ZTP_GIT_BRANCH:?ZTP_GIT_BRANCH is required}"
  : "${IBI_REPLACEMENT_HOST:?IBI_REPLACEMENT_HOST is required}"
  : "${IBI_REPLACEMENT_MAC:?IBI_REPLACEMENT_MAC is required}"
  : "${IBI_REPLACEMENT_IP:?IBI_REPLACEMENT_IP is required}"
  [[ "${CLUSTER_NAME}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]
  [[ "${SEED_SPOKE_CLUSTER}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]
  [[ "${IBI_REPLACEMENT_HOST}" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]]
  [[ "${IBI_REPLACEMENT_MAC}" =~ ^([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}$ ]]
  [[ "${IBI_REPLACEMENT_IP}" =~ ^[0-9]+(\.[0-9]+){3}$ ]]
  [[ "${MIRROR_REGISTRY}" =~ ^[a-zA-Z0-9.:-]+$ ]]
  [[ "${ZTP_GIT_REPO}" =~ ^https://[a-zA-Z0-9./:_-]+$ ]]
  [[ "${ZTP_GIT_BRANCH}" =~ ^[a-zA-Z0-9._/-]+$ ]]
  [[ "${VERSION}" =~ ^[0-9]+\.[0-9]+$ ]]
  if [[ ! -s "${SHARED_DIR}/ibi-seed-version" ]]; then
    echo "Missing recorded seed version." >&2
    return 1
  fi
  SEED_VERSION=$(<"${SHARED_DIR}/ibi-seed-version")
  [[ "${SEED_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$ ]]
  [[ "${SEED_VERSION}" == "${VERSION}."* ]]
  SEED_HUB_KUBECONFIG="/home/telcov10n/project/generated/${CLUSTER_NAME}/auth/kubeconfig"
}

restore_seed_inventory() {
  local name
  INVENTORY_PATH=/eco-ci-cd/inventories/ocp-deployment
  mkdir -p "${INVENTORY_PATH}/group_vars" "${INVENTORY_PATH}/host_vars"
  for name in all bastions; do
    cp "${SHARED_DIR}/seed-${name}" "${INVENTORY_PATH}/group_vars/${name}"
  done
  cp "${SHARED_DIR}/seed-bastion" "${INVENTORY_PATH}/host_vars/bastion"
}

create_work_directories() {
  TEMP_DIR=$(mktemp -d /tmp/ibi-replacement-preinstall.XXXXXX)
  trap cleanup EXIT
  WORK_DIR="/tmp/eco_gotests_ibi_preinstall/${TEMP_DIR##*/}"
  REPORT_DIR="${ARTIFACT_DIR}/ibi-replacement-preinstall"
  HTTP_SUBDIR="${TEMP_DIR##*/}"
  mkdir -p "${REPORT_DIR}"
}

configure_ssh() {
  cp /var/group_variables/common/all/ansible_ssh_private_key "${TEMP_DIR}/ssh-key"
  chmod 600 "${TEMP_DIR}/ssh-key"

  BASTION_IP=$(grep -oP '(?<=ansible_host: ).*' "${INVENTORY_PATH}/host_vars/bastion" | sed "s/'//g")
  BASTION_USER=$(grep -oP '(?<=ansible_user: ).*' "${INVENTORY_PATH}/group_vars/all" | sed "s/'//g")
  [[ -n "${BASTION_IP}" && -n "${BASTION_USER}" ]]

  SSH_OPTS=(
    -i "${TEMP_DIR}/ssh-key"
    -o BatchMode=yes
    -o ConnectTimeout=30
    -o ServerAliveInterval=30
    -o ServerAliveCountMax=6
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
  )
}

redact_bastion() {
  local line
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line//${BASTION_USER}@${BASTION_IP}/<bastion>}"
    line="${line//${BASTION_IP}/<bastion>}"
    printf '%s\n' "${line}"
  done
}

verify_installer_version() {
  local installer_output
  local installer_version

  echo "Checking the cached installer for OpenShift ${SEED_VERSION}."
  if ! installer_output=$(ssh "${SSH_OPTS[@]}" "${BASTION_USER}@${BASTION_IP}" \
    "/opt/cache/${SEED_VERSION}/openshift-install version" 2>&1); then
    printf '%s\n' "${installer_output}" | redact_bastion >&2
    return 1
  fi

  installer_version=$(printf '%s\n' "${installer_output}" | awk '$1 ~ /(^|\/)openshift-install$/ && NF == 2 { print $2 }')
  if [[ "${installer_version}" != "${SEED_VERSION}" ]]; then
    echo "Cached installer version '${installer_version}' does not match the recorded seed version '${SEED_VERSION}'." >&2
    return 1
  fi
}

verify_seed_image() {
  local digest
  digest=$(ssh "${SSH_OPTS[@]}" "${BASTION_USER}@${BASTION_IP}" \
    "bash -s -- '${SEED_HUB_KUBECONFIG}' '${MIRROR_REGISTRY}/ibu/seed:${VERSION}' '${SEED_VERSION}'" <<'REMOTE'
set +x
set -euo pipefail
umask 077
auth_file=$(mktemp /tmp/ibi-seed-auth.XXXXXX)
trap 'rm -f -- "$auth_file"' EXIT
oc --kubeconfig="$1" -n openshift-config get secret pull-secret \
  -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d > "$auth_file"
metadata=$(skopeo inspect --tls-verify=false --authfile "$auth_file" "docker://$2")
jq -e --arg version "$3" '
  .Labels["com.openshift.lifecycle-agent.seed_cluster_info"]
  | fromjson | .seed_cluster_ocp_version == $version
' <<<"$metadata" >/dev/null
jq -er '.Digest' <<<"$metadata"
REMOTE
  )
  [[ "${digest}" =~ ^sha256:[a-f0-9]{64}$ ]]
  SEED_IMAGE="${MIRROR_REGISTRY}/ibu/seed@${digest}"
}

prepare_launcher() {
  local site_config_url="${ZTP_GIT_REPO%.git}/-/raw/${ZTP_GIT_BRANCH}/${VERSION}/${SEED_SPOKE_CLUSTER}/clusterinstance"
  cd /eco-ci-cd

  ansible bastion -i "${INVENTORY_PATH}/build-inventory.py" \
    --private-key "${TEMP_DIR}/ssh-key" \
    --extra-vars "ibi_http_subdir=${HTTP_SUBDIR}" \
    -m ansible.builtin.file \
    -a '{"path":"{{ http_store_path | default(\"/opt/http_store/data\") }}/{{ ibi_http_subdir }}","state":"directory","mode":"0755"}' \
    2>&1 | redact_bastion | tee "${REPORT_DIR}/http-setup.log"

  ansible-playbook ./playbooks/ran/ibi-preinstall.yml \
    -i "${INVENTORY_PATH}/build-inventory.py" \
    --private-key "${TEMP_DIR}/ssh-key" \
    --limit bastion --tags setup \
    --extra-vars "ibi_hub_kubeconfig=${SEED_HUB_KUBECONFIG}" \
    --extra-vars "ibi_seed_image=${SEED_IMAGE}" \
    --extra-vars "ibi_seed_version=${SEED_VERSION}" \
    --extra-vars "ibi_preinstall_registry=${MIRROR_REGISTRY}" \
    --extra-vars "ibi_cluster_instance_url=${site_config_url}/clusterinstance.yaml" \
    --extra-vars "ibi_config_template_url=${site_config_url}/preinstall-test/image-based-installation-config.yaml" \
    --extra-vars "ibi_openshift_install_path=/opt/cache/${SEED_VERSION}/openshift-install" \
    --extra-vars "ibi_work_dir=${WORK_DIR} ibi_http_subdir=${HTTP_SUBDIR}" \
    --extra-vars "eco_gotests_image=quay.io/ocp-edge-qe/eco-gotests:latest" \
    --extra-vars '{
      "ibi_ssh_private_key_path": "/home/telcov10n/.ssh/id_rsa",
      "ibi_http_dir": "{{ http_store_path | default(\"/opt/http_store/data\") }}/{{ ibi_http_subdir }}",
      "ibi_http_base_url": "http://{{ ansible_host }}:{{ share_http_iso_port }}/{{ ibi_http_subdir }}",
      "ibi_test_timeout": "3h",
      "ibi_skip_tls_verify": true
    }' \
    2>&1 | redact_bastion | tee "${REPORT_DIR}/setup.log"

  # Validate the fetched ClusterInstance before releasing seed hardware.
  ssh "${SSH_OPTS[@]}" "${BASTION_USER}@${BASTION_IP}" \
    "bash -s -- '${SEED_HUB_KUBECONFIG}' '${site_config_url}' '${IBI_REPLACEMENT_HOST}' '${IBI_REPLACEMENT_MAC}'" \
    <<'REMOTE' 2>&1 | redact_bastion | tee "${REPORT_DIR}/input-check.log"
set +x
set -euo pipefail
instance=$(oc --kubeconfig="$1" create --dry-run=client --validate=false \
  -f "$2/clusterinstance.yaml" -o json)
jq -e --arg host "$3" --arg mac "${4,,}" '
  .spec.nodes as $nodes
  | .kind == "ClusterInstance"
    and ($nodes | length) == 1
    and $nodes[0].hostName == $host
    and (($nodes[0].bootMACAddress | ascii_downcase) == $mac)
' <<<"$instance" >/dev/null
template=$(curl --fail --silent --show-error --max-time 60 \
  "$2/preinstall-test/image-based-installation-config.yaml")
disk=$(jq -er '.spec.nodes[0].rootDeviceHints.wwn' <<<"$instance")
grep -Fxq "installationDisk: /dev/disk/by-id/wwn-$disk" <<<"$template"
grep -Fxq "extraPartitionLabel: varlibcontainers" <<<"$template"
REMOTE
}

verify_http_and_dns() {
  ansible bastion -i "${INVENTORY_PATH}/build-inventory.py" \
    --private-key "${TEMP_DIR}/ssh-key" \
    --extra-vars "ibi_http_subdir=${HTTP_SUBDIR} eco_gotests_image=quay.io/ocp-edge-qe/eco-gotests:latest" \
    --extra-vars "replacement_host=${IBI_REPLACEMENT_HOST} replacement_ip=${IBI_REPLACEMENT_IP}" \
    -m ansible.builtin.shell -a '
set -eu
resolved=$(podman run --rm --pull=never --net=host \
  --userns=keep-id:uid=1000,gid=1000 \
  -v "{{ http_store_path | default("/opt/http_store/data") }}/{{ ibi_http_subdir }}:/ibi-http:rw,z" \
  --entrypoint /bin/bash {{ eco_gotests_image | quote }} \
  -c '"'"'set -eu; printf "%s\n" "$1" > /ibi-http/.write-check; getent ahostsv4 "$2"'"'"' \
  bash {{ ibi_http_subdir | quote }} {{ replacement_host | quote }})
addresses=$(printf "%s\n" "$resolved" | cut -d " " -f1 | sort -u)
test "$addresses" = {{ replacement_ip | quote }}
content=$(curl --fail --silent --show-error --max-time 30 \
  "http://{{ ansible_host }}:{{ share_http_iso_port }}/{{ ibi_http_subdir }}/.write-check")
test "$content" = {{ ibi_http_subdir | quote }}
' 2>&1 | redact_bastion | tee "${REPORT_DIR}/preflight.log"
}

release_seed_host() {
  ssh "${SSH_OPTS[@]}" "${BASTION_USER}@${BASTION_IP}" \
    "bash -s -- '${SEED_HUB_KUBECONFIG}' '${SEED_SPOKE_CLUSTER}' '${IBI_REPLACEMENT_HOST}' '${IBI_REPLACEMENT_MAC}'" \
    <<'REMOTE' 2>&1 | redact_bastion | tee "${REPORT_DIR}/cleanup.log"
set +x
set -euo pipefail
export KUBECONFIG=$1
seed_cluster=$2
replacement_host=$3
replacement_mac=${4,,}

remaining_apps=$(oc -n openshift-gitops get applications.argoproj.io \
  clusters policies --ignore-not-found -o name)
remaining_managed_cluster=$(oc get managedclusters.cluster.open-cluster-management.io \
  "$seed_cluster" --ignore-not-found -o name)
if [[ -n "$remaining_apps" || -n "$remaining_managed_cluster" ]]; then
  echo "Seed detachment is incomplete; refusing hardware cleanup." >&2
  exit 1
fi

seed_instance=$(oc -n "$seed_cluster" get \
  clusterinstances.siteconfig.open-cluster-management.io "$seed_cluster" \
  --ignore-not-found -o json)
if [[ -n "$seed_instance" ]]; then
  jq -e --arg host "$replacement_host" --arg mac "$replacement_mac" '
    .spec.nodes as $nodes
    | ($nodes | length) == 1
      and $nodes[0].hostName == $host
      and (($nodes[0].bootMACAddress | ascii_downcase) == $mac)
  ' <<<"$seed_instance" >/dev/null
  oc -n "$seed_cluster" delete \
    clusterinstances.siteconfig.open-cluster-management.io "$seed_cluster" \
    --wait=true --timeout=30m
fi

remaining_host=$(oc -n "$seed_cluster" get baremetalhosts.metal3.io \
  "$replacement_host" --ignore-not-found -o json)
if [[ -n "$remaining_host" ]]; then
  jq -e --arg mac "$replacement_mac" '
    ((.spec.bootMACAddress | ascii_downcase) == $mac)
    and ((.metadata.ownerReferences // []) | length == 0)
  ' <<<"$remaining_host" >/dev/null
  oc -n "$seed_cluster" delete baremetalhosts.metal3.io \
    "$replacement_host" --wait=true --timeout=30m
fi

remaining_hosts=$(oc get baremetalhosts.metal3.io -A -o json)
if ! jq -e --arg host "$replacement_host" --arg mac "$replacement_mac" '
  [.items[] | select(
    .metadata.name == $host
    or ((.spec.bootMACAddress // "" | ascii_downcase) == $mac)
  )] | length == 0
' <<<"$remaining_hosts" >/dev/null; then
  echo "Replacement hardware is still registered to a BareMetalHost." >&2
  exit 1
fi
REMOTE
}

run_preinstall() {
  ssh "${SSH_OPTS[@]}" "${BASTION_USER}@${BASTION_IP}" \
    "cd '${WORK_DIR}' && exec ./eco-gotests-ibi-preinstall-run.sh" \
    2>&1 | redact_bastion | tee "${REPORT_DIR}/runner.log"
}

collect_reports() {
  scp -q -r "${SSH_OPTS[@]}" \
    "${BASTION_USER}@${BASTION_IP}:${WORK_DIR}/report" \
    "${REPORT_DIR}/" \
    2>&1 | redact_bastion
}

main() {
  if [[ -f "${SHARED_DIR}/skip.txt" || "${IBI_REPLACEMENT_PREINSTALL_ENABLED}" == false ]]; then
    echo "Skipping IBI replacement preinstall."
    return 0
  fi

  [[ "${IBI_REPLACEMENT_PREINSTALL_ENABLED}" == true ]]
  validate_inputs
  restore_seed_inventory
  create_work_directories
  configure_ssh
  verify_installer_version
  verify_seed_image
  prepare_launcher
  verify_http_and_dns
  release_seed_host

  local run_rc=0
  local copy_rc=0

  run_preinstall || run_rc=$?
  collect_reports || copy_rc=$?

  # Preserve the execution failure after collecting reports.
  if (( run_rc != 0 )); then
    echo "IBI replacement preinstall failed; exit status: ${run_rc}."
    return "${run_rc}"
  fi
  if (( copy_rc != 0 )); then
    echo "IBI replacement preinstall reports could not be collected."
    return "${copy_rc}"
  fi

  echo "IBI replacement preinstall execution and report collection completed."
}

main "$@"
