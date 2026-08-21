#!/bin/bash

set -exuo pipefail

HCP_CLI="/usr/bin/hcp"

MCE=${MCE_VERSION:-""}
CLUSTER_NAME=$(echo -n "${PROW_JOB_ID}"|sha256sum|cut -c-20)
if [[ -n ${MCE} ]] ; then
    CLUSTER_NAMESPACE_PREFIX=local-cluster
else
    CLUSTER_NAMESPACE_PREFIX=clusters
fi

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
    # shellcheck source=/dev/null
    source "${SHARED_DIR}/proxy-conf.sh"
fi

if [[ -n ${MCE} ]] ; then
  arch=$(arch)
  if [ "$arch" == "x86_64" ]; then
    downURL=$(oc get ConsoleCLIDownload hcp-cli-download -o=jsonpath='{.spec.links[?(@.text=="Download hcp CLI for Linux for x86_64")].href}') && curl -k --output "/tmp/hcp.tar.gz" "${downURL}"
    cd /tmp && tar -xvf "/tmp/hcp.tar.gz"
    chmod +x "/tmp/hcp"
    HCP_CLI="/tmp/hcp"
    cd -
  fi
fi

function support_np_skew() {
  local EXTRA_FLARGS=""
  if [[ -n "$HOSTEDCLUSTER_RELEASE_IMAGE_LATEST" && -n "$NODEPOOL_RELEASE_IMAGE_LATEST" && -n "$MCE" && "$HOSTEDCLUSTER_RELEASE_IMAGE_LATEST" != "$NODEPOOL_RELEASE_IMAGE_LATEST" ]]; then
    curl -L "https://github.com/mikefarah/yq/releases/download/v4.31.2/yq_linux_$(uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/')" -o /tmp/yq && chmod +x /tmp/yq
    # >= 2.7: "--render-sensitive --render", else: "--render"
    if [[ "$(printf '%s\n' "2.7" "$MCE_VERSION" | sort -V | head -n1)" == "2.7" ]]; then
      EXTRA_FLARGS+="--render-sensitive --render > /tmp/hc.yaml "
    else
      EXTRA_FLARGS+="--render > /tmp/hc.yaml "
    fi
    EXTRA_FLARGS+="&& /tmp/yq e -i '(select(.kind == \"NodePool\").spec.release.image) = \"$NODEPOOL_RELEASE_IMAGE_LATEST\"' /tmp/hc.yaml "
    EXTRA_FLARGS+="&& oc apply -f /tmp/hc.yaml"
  fi
  echo "$EXTRA_FLARGS"
}

# discover_ovn_container_names sets OVN_OVS_CONTAINER and OVN_NBDB_CONTAINER
# based on the containers available in the ovnkube-node pod.
# In OCP 4.17+ (INTERCONNECT mode), ovnkube-node container was replaced by ovnkube-controller.
discover_ovn_container_names() {
  local pod_name="$1"
  local containers

  containers=$(oc get pod -n openshift-ovn-kubernetes "${pod_name}" -o jsonpath='{.spec.containers[*].name}' 2>/dev/null)

  # Discover OVS container (for ovs-vsctl commands)
  for candidate in ovnkube-controller ovnkube-node; do
    if [[ " ${containers} " == *" ${candidate} "* ]]; then
      OVN_OVS_CONTAINER="${candidate}"
      break
    fi
  done

  # Discover NBDB container (for ovn-nbctl commands)
  for candidate in nbdb ovnkube-controller ovnkube-node; do
    if [[ " ${containers} " == *" ${candidate} "* ]]; then
      OVN_NBDB_CONTAINER="${candidate}"
      break
    fi
  done

  if [[ -z "${OVN_OVS_CONTAINER}" ]] || [[ -z "${OVN_NBDB_CONTAINER}" ]]; then
    echo "ERROR: unable to discover OVN containers in pod ${pod_name}" >&2
    echo "  Available containers: ${containers}" >&2
    return 1
  fi

  echo "INFO: Discovered OVN containers - OVS: ${OVN_OVS_CONTAINER}, NBDB: ${OVN_NBDB_CONTAINER}"
  return 0
}

# find_localnet_lsps_for_nad prints LSP names (one per line) for a NAD on a node's OVN DB.
find_localnet_lsps_for_nad() {
  local multi_ns="$1"
  local ovn_pod="$2"
  local nad_name="$3"
  local subnet="$4"
  local lsp_names subnet_prefix name ip line

  lsp_names=$(oc exec -n openshift-ovn-kubernetes "${ovn_pod}" -c "${OVN_NBDB_CONTAINER}" -- \
    ovn-nbctl --columns=name --bare find Logical_Switch_Port \
    "external_ids:k8s.ovn.org/nad=${multi_ns}/${nad_name}" 2>/dev/null || true)

  if [[ -z "${lsp_names}" && -n "${subnet}" ]]; then
    subnet_prefix=$(echo "${subnet}" | cut -d'.' -f1-3)
    while IFS= read -r line; do
      [[ -z "${line}" ]] && continue
      name=$(echo "${line}" | awk '{print $1}')
      ip=$(echo "${line}" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
      if [[ "${ip}" == "${subnet_prefix}."* ]]; then
        echo "${name}"
      fi
    done < <(oc exec -n openshift-ovn-kubernetes "${ovn_pod}" -c "${OVN_NBDB_CONTAINER}" -- \
      ovn-nbctl --columns=name,dynamic_addresses --bare find Logical_Switch_Port \
      "external_ids:k8s.ovn.org/topology=localnet" 2>/dev/null || true)
    return 0
  fi

  for name in ${lsp_names}; do
    echo "${name}"
  done
}

lsp_has_dhcp_configured() {
  local ovn_pod="$1"
  local lsp_name="$2"
  local existing_dhcp

  existing_dhcp=$(oc exec -n openshift-ovn-kubernetes "${ovn_pod}" -c "${OVN_NBDB_CONTAINER}" -- \
    ovn-nbctl get Logical_Switch_Port "${lsp_name}" dhcpv4_options 2>/dev/null || true)
  [[ -n "${existing_dhcp}" && "${existing_dhcp}" != "[]" ]]
}

configure_localnet_multi_dhcp_on_lsp() {
  local ovn_pod="$1"
  local lsp_name="$2"
  local subnet="$3"
  local net_index="$4"
  local subnet_gw server_mac dhcp_uuid

  if lsp_has_dhcp_configured "${ovn_pod}" "${lsp_name}"; then
    return 0
  fi

  server_mac=$(printf "c0:ff:ee:00:00:%02x" "${net_index}")
  if [[ ${net_index} -eq 1 ]]; then
    dhcp_uuid=$(oc exec -n openshift-ovn-kubernetes "${ovn_pod}" -c "${OVN_NBDB_CONTAINER}" -- \
      ovn-nbctl create DHCP_Options cidr="${subnet}" \
      options='"lease_time"="3500" "router"="'"${LOCALNET_MULTI_PRIMARY_GATEWAY}"'" "dns_server"="'"${LOCALNET_MULTI_PRIMARY_DNS}"'" "server_id"="'"${LOCALNET_MULTI_PRIMARY_GATEWAY}"'" "server_mac"="'"${server_mac}"'"' \
      2>/dev/null)
  else
    subnet_gw=$(echo "${subnet}" | sed 's|/.*||' | sed 's/\.0$/.1/')
    dhcp_uuid=$(oc exec -n openshift-ovn-kubernetes "${ovn_pod}" -c "${OVN_NBDB_CONTAINER}" -- \
      ovn-nbctl create DHCP_Options cidr="${subnet}" \
      options='"lease_time"="3500" "server_id"="'"${subnet_gw}"'" "server_mac"="'"${server_mac}"'"' \
      2>/dev/null)
  fi

  if [[ -z "${dhcp_uuid}" ]]; then
    return 1
  fi

  oc exec -n openshift-ovn-kubernetes "${ovn_pod}" -c "${OVN_NBDB_CONTAINER}" -- \
    ovn-nbctl lsp-set-dhcpv4-options "${lsp_name}" "${dhcp_uuid}" 2>/dev/null
  oc exec -n openshift-ovn-kubernetes "${ovn_pod}" -c "${OVN_NBDB_CONTAINER}" -- \
    ovn-nbctl clear Logical_Switch_Port "${lsp_name}" port_security 2>/dev/null
  return 0
}

count_configured_localnet_lsps_for_nad() {
  local multi_ns="$1"
  local nad_name="$2"
  local subnet="$3"
  local count=0 node ovn_pod lsp_name

  for node in $(oc get nodes -o jsonpath='{.items[*].metadata.name}'); do
    ovn_pod=$(oc get pods -n openshift-ovn-kubernetes -l app=ovnkube-node \
      --field-selector "spec.nodeName=${node}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    [[ -z "${ovn_pod}" ]] && continue
    while IFS= read -r lsp_name; do
      [[ -z "${lsp_name}" ]] && continue
      if lsp_has_dhcp_configured "${ovn_pod}" "${lsp_name}"; then
        count=$((count + 1))
      fi
    done < <(find_localnet_lsps_for_nad "${multi_ns}" "${ovn_pod}" "${nad_name}" "${subnet}")
  done
  echo "${count}"
}

configure_localnet_multi_dhcp_on_nodes() {
  local multi_ns="$1"
  local network_count="$2"
  local -a target_nodes=()
  local node ovn_pod i nad_name subnet lsp_name pending

  if [[ $# -ge 3 && -n "${3:-}" ]]; then
    read -ra target_nodes <<< "${3}"
  else
    read -ra target_nodes <<< "$(oc get nodes -o jsonpath='{.items[*].metadata.name}')"
  fi

  pending=0
  for node in "${target_nodes[@]}"; do
    [[ -z "${node}" ]] && continue
    ovn_pod=$(oc get pods -n openshift-ovn-kubernetes -l app=ovnkube-node \
      --field-selector "spec.nodeName=${node}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [[ -z "${ovn_pod}" ]]; then
      echo "WARNING: No ovnkube-node pod on node ${node}, skipping DHCP config"
      pending=$((pending + 1))
      continue
    fi

    for i in $(seq 1 "${network_count}"); do
      nad_name="localnet-${i}"
      subnet="${SUBNETS[$((i - 1))]}"
      while IFS= read -r lsp_name; do
        [[ -z "${lsp_name}" ]] && continue
        if lsp_has_dhcp_configured "${ovn_pod}" "${lsp_name}"; then
          continue
        fi
        if configure_localnet_multi_dhcp_on_lsp "${ovn_pod}" "${lsp_name}" "${subnet}" "${i}"; then
          echo "  Configured DHCP for ${nad_name} (LSP=${lsp_name}, node=${node})"
        else
          echo "  WARNING: Failed to configure DHCP for ${nad_name} (LSP=${lsp_name}, node=${node})"
          pending=$((pending + 1))
        fi
      done < <(find_localnet_lsps_for_nad "${multi_ns}" "${ovn_pod}" "${nad_name}" "${subnet}")
    done
  done

  PRIMARY_CONFIGURED=$(count_configured_localnet_lsps_for_nad "${multi_ns}" "localnet-1" "${SUBNETS[0]}")
  echo "localnet-multi DHCP: ${PRIMARY_CONFIGURED}/${HYPERSHIFT_NODE_COUNT} primary LSPs configured, ${pending} pending on targeted nodes"
  [[ ${pending} -eq 0 ]]
}

wait_for_localnet_multi_vmis_running() {
  local multi_ns="$1"
  local running_count=0

  echo "Waiting for localnet-multi worker VMIs to reach Running..."
  for _ in $(seq 1 120); do
    running_count=$(oc get vmi -n "${multi_ns}" --no-headers 2>/dev/null \
      | awk '$3 ~ /Running/ {count++} END {print count+0}')
    if [[ "${running_count}" -ge "${HYPERSHIFT_NODE_COUNT}" ]]; then
      echo "All ${running_count} worker VMIs are Running"
      return 0
    fi
    echo "Waiting for worker VMIs... (${running_count}/${HYPERSHIFT_NODE_COUNT} running)"
    sleep 10
  done

  echo "WARNING: Only ${running_count}/${HYPERSHIFT_NODE_COUNT} worker VMIs running after 20 minutes"
  return 1
}

prepare_localnet_multi_dhcp_renewal_secret() {
  local multi_ns="$1"
  local ssh_key_secret="${CLUSTER_NAME}-ssh-key"

  if ! oc get secret -n "${CLUSTER_NAMESPACE_PREFIX}" "${ssh_key_secret}" &>/dev/null; then
    echo "WARNING: SSH key secret ${ssh_key_secret} not found, skipping DHCP renewal"
    return 1
  fi

  oc label namespace "${multi_ns}" pod-security.kubernetes.io/enforce=privileged --overwrite 2>/dev/null || true
  oc get secret -n "${CLUSTER_NAMESPACE_PREFIX}" "${ssh_key_secret}" -o json \
    | python3 -c "import sys,json; s=json.load(sys.stdin); s['metadata']={'name':s['metadata']['name'],'namespace':'${multi_ns}'}; print(json.dumps(s))" \
    | oc apply -f - 2>/dev/null || true
  return 0
}

renew_localnet_multi_dhcp_on_vmi() {
  local multi_ns="$1"
  local network_count="$2"
  local vmi="$3"
  local vmi_ip vmi_node renew_pod

  vmi_ip=$(oc get vmi -n "${multi_ns}" "${vmi}" -o jsonpath='{.status.interfaces[0].ipAddress}' 2>/dev/null)
  vmi_node=$(oc get vmi -n "${multi_ns}" "${vmi}" -o jsonpath='{.status.nodeName}' 2>/dev/null)
  if [[ -z "${vmi_ip}" || -z "${vmi_node}" ]]; then
    echo "WARNING: Could not determine IP/node for VMI ${vmi}, skipping DHCP renewal"
    return 1
  fi

  echo "Forcing DHCP renewal on VMI ${vmi} (${vmi_ip}) via pod on ${vmi_node}..."
  renew_pod="dhcp-renew-${vmi##*-}"
  renew_devices=""
  for idx in $(seq "${network_count}" -1 1); do
    renew_devices="${renew_devices} enp${idx}s0"
  done
  # Unquoted heredoc: escape inner-shell vars (e.g. \${VMI_IP}) so set -u does not
  # expand them in the outer shell before oc apply.
  # Use nmcli device reapply by interface name; initrd profiles are "Wired Connection"
  # (not "Wired connection N") so connection-name toggles are unreliable.
  if ! cat <<RENEW_EOF | oc apply -f -; then
apiVersion: v1
kind: Pod
metadata:
  name: ${renew_pod}
  namespace: ${multi_ns}
spec:
  nodeSelector:
    kubernetes.io/hostname: ${vmi_node}
  restartPolicy: Never
  volumes:
  - name: ssh-key
    secret:
      secretName: ${CLUSTER_NAME}-ssh-key
      defaultMode: 384
  containers:
  - name: renew
    image: registry.access.redhat.com/ubi9/ubi-minimal:latest
    env:
    - name: VMI_IP
      value: "${vmi_ip}"
    volumeMounts:
    - name: ssh-key
      mountPath: /ssh
    command:
    - sh
    - -c
    - |
      microdnf install -y openssh-clients 2>/dev/null
      if [ -f /ssh/id_rsa ]; then
        cp /ssh/id_rsa /tmp/key
      else
        cp /ssh/id_ed25519 /tmp/key
      fi
      chmod 600 /tmp/key
      renew_ok=1
      for attempt in 1 2 3 4 5; do
        if ssh -i /tmp/key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
             -o ConnectTimeout=15 "core@\${VMI_IP}" \
             "for dev in${renew_devices}; do sudo nmcli device set \\\$dev ipv6.method disabled 2>/dev/null || true; sudo nmcli device reapply \\\$dev 2>/dev/null || { sudo nmcli device disconnect \\\$dev 2>/dev/null; sudo nmcli device connect \\\$dev 2>/dev/null; }; done; echo Default IPv4 route:; ip route show default 2>/dev/null || echo '(none)'" 2>&1; then
          renew_ok=0
          break
        fi
        echo "SSH attempt \${attempt} failed, retrying in 5s..."
        sleep 5
      done
      exit \${renew_ok}
RENEW_EOF
    echo "WARNING: Failed to create DHCP renewal pod ${renew_pod} for ${vmi}"
    return 1
  fi
  oc wait pod/"${renew_pod}" -n "${multi_ns}" \
    --for=jsonpath='{.status.phase}'=Succeeded --timeout=180s 2>&1 || true
  echo "--- DHCP renewal output for ${vmi} ---"
  oc logs "${renew_pod}" -n "${multi_ns}" 2>&1 | tail -20
  if ! oc logs "${renew_pod}" -n "${multi_ns}" 2>&1 | grep -q "via ${LOCALNET_MULTI_PRIMARY_GATEWAY}"; then
    echo "WARNING: VMI ${vmi} may still lack default route via ${LOCALNET_MULTI_PRIMARY_GATEWAY}"
    oc delete pod "${renew_pod}" -n "${multi_ns}" --ignore-not-found 2>/dev/null || true
    return 1
  fi
  oc delete pod "${renew_pod}" -n "${multi_ns}" --ignore-not-found 2>/dev/null || true
  return 0
}

renew_localnet_multi_dhcp_for_running_vmis() {
  local multi_ns="$1"
  local network_count="$2"
  local vmi phase failures=0

  for vmi in $(oc get vmi -n "${multi_ns}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    phase=$(oc get vmi -n "${multi_ns}" "${vmi}" -o jsonpath='{.status.phase}' 2>/dev/null || true)
    [[ "${phase}" == "Running" ]] || continue
    if ! renew_localnet_multi_dhcp_on_vmi "${multi_ns}" "${network_count}" "${vmi}"; then
      failures=$((failures + 1))
    fi
  done
  [[ ${failures} -eq 0 ]]
}

ensure_localnet_multi_worker_networking() {
  local multi_ns="$1"
  local network_count="$2"
  local vmi node vmi_nodes=""

  IFS=',' read -ra SUBNETS <<< "${LOCALNET_MULTI_SUBNETS}"

  wait_for_localnet_multi_vmis_running "${multi_ns}" || true

  for vmi in $(oc get vmi -n "${multi_ns}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    node=$(oc get vmi -n "${multi_ns}" "${vmi}" -o jsonpath='{.status.nodeName}' 2>/dev/null || true)
    [[ -n "${node}" ]] && vmi_nodes="${vmi_nodes} ${node}"
  done
  vmi_nodes=$(echo "${vmi_nodes}" | tr ' ' '\n' | sort -u | tr '\n' ' ')

  echo "Ensuring OVN DHCP on worker node(s):${vmi_nodes}"
  configure_localnet_multi_dhcp_on_nodes "${multi_ns}" "${network_count}" "${vmi_nodes}" || true

  if ! prepare_localnet_multi_dhcp_renewal_secret "${multi_ns}"; then
    return 1
  fi
  if ! renew_localnet_multi_dhcp_for_running_vmis "${multi_ns}" "${network_count}"; then
    echo "WARNING: DHCP renewal failed on one or more worker VMIs"
    return 1
  fi
  return 0
}

if [[ ! -f $HCP_CLI ]]; then
  # we have to fall back to hypershift in cases where the new hcp cli isn't available yet
  HCP_CLI="/usr/bin/hypershift"
fi
echo "Using $HCP_CLI for cli"

RUN_HOSTEDCLUSTER_CREATION="${RUN_EXTERNAL_INFRA_TEST:-$RUN_HOSTEDCLUSTER_CREATION}"

if [ "${RUN_HOSTEDCLUSTER_CREATION}" != "true" ]
then
  echo "Creation of a kubevirt hosted cluster has been skipped."
  exit 0
fi


if [ -n "${KUBEVIRT_CSI_INFRA}" ]
then
  EXTRA_ARGS="${EXTRA_ARGS} --infra-storage-class-mapping=${KUBEVIRT_CSI_INFRA}/${KUBEVIRT_CSI_INFRA}"
fi

if [ "$(oc get infrastructure cluster -o=jsonpath='{.status.platformStatus.type}')" == "AWS" ]; then
  if [ -z "$ETCD_STORAGE_CLASS" ]; then
    echo "AWS infra detected. Setting --etcd-storage-class"
    ETCD_STORAGE_CLASS="gp3-csi"
  fi
fi

if [ -n "${ETCD_STORAGE_CLASS}" ]
then
  EXTRA_ARGS="${EXTRA_ARGS} --etcd-storage-class=${ETCD_STORAGE_CLASS}"
fi

PULL_SECRET_PATH="/etc/ci-pull-credentials/.dockerconfigjson"
ICSP_COMMAND=""
if [[ $ENABLE_ICSP == "true" ]]; then
  ICSP_COMMAND=$(echo "--image-content-sources ${SHARED_DIR}/mgmt_icsp.yaml")
  echo "extract secret/pull-secret"
  oc extract secret/pull-secret -n openshift-config --to=/tmp --confirm
  PULL_SECRET_PATH="/tmp/.dockerconfigjson"
  if [ ! -f /tmp/yq-v4 ]; then
    curl -L "https://github.com/mikefarah/yq/releases/download/v4.30.5/yq_linux_$(uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/')" \
    -o /tmp/yq-v4 && chmod +x /tmp/yq-v4
  fi
  oc get imagecontentsourcepolicy -oyaml | /tmp/yq-v4 '.items[] | .spec.repositoryDigestMirrors' > "${SHARED_DIR}/mgmt_icsp.yaml"
fi

# Enable wildcard routes on the management cluster
oc patch ingresscontroller -n openshift-ingress-operator default --type=json -p \
  '[{ "op": "add", "path": "/spec/routeAdmission", "value": {wildcardPolicy: "WildcardsAllowed"}}]'


RELEASE_IMAGE=${HYPERSHIFT_HC_RELEASE_IMAGE:-$RELEASE_IMAGE_LATEST}

if [[ "${DISCONNECTED}" == "true" ]];
then
  mirror_registry=$(oc get imagecontentsourcepolicy cnv-repo -o=jsonpath='{.spec.repositoryDigestMirrors[0].mirrors[0]}')
  mirror_registry=${mirror_registry%%/*}
  if [[ $mirror_registry == "" ]] ; then
      echo "Warning: Can not find the mirror registry, abort !!!"
      exit 1
  fi
  echo "mirror registry is ${mirror_registry}"

  OLM_CATALOGS_R_OVERRIDES=registry.redhat.io/redhat=${mirror_registry}/olm-index
  PAYLOADIMAGE=$(oc get clusterversion version -ojsonpath='{.status.desired.image}')
  RELEASE_IMAGE="${PAYLOADIMAGE}"

  if [ ! -f "${SHARED_DIR}/ho_operator_image" ] ; then
      echo "Warning: Can not find ho_operator_image, abort !!!"
      exit 1
  fi
  HO_OPERATOR_IMAGE=$(cat "${SHARED_DIR}/ho_operator_image")

  EXTRA_ARGS="${EXTRA_ARGS} --additional-trust-bundle=${SHARED_DIR}/registry.2.crt --annotations=hypershift.openshift.io/control-plane-operator-image=${HO_OPERATOR_IMAGE} --annotations=hypershift.openshift.io/olm-catalogs-is-registry-overrides=${OLM_CATALOGS_R_OVERRIDES}"

  ### workaround for https://issues.redhat.com/browse/OCPBUGS-32770
  if [[ -z ${MCE} ]] ; then
    if [ ! -f "${SHARED_DIR}/capi_provider_kubevirt_image" ] ; then
        echo "Warning: Can not find capi_provider_kubevirt_image, abort !!!"
        exit 1
    fi
    CAPI_PROVIDER_KUBEVIRT_IMAGE=$(cat "${SHARED_DIR}/capi_provider_kubevirt_image")

    EXTRA_ARGS="${EXTRA_ARGS} --annotations=hypershift.openshift.io/capi-provider-kubevirt-image=${CAPI_PROVIDER_KUBEVIRT_IMAGE}"
  fi
  ###

fi

oc create namespace "${CLUSTER_NAMESPACE_PREFIX}" --dry-run=client -o yaml | oc apply -f -
oc create ns "${CLUSTER_NAMESPACE_PREFIX}-${CLUSTER_NAME}"
if [[ -n "${ATTACH_DEFAULT_NETWORK}" ]]; then
  if [[ "${ATTACH_DEFAULT_NETWORK}" == "localnet" ]]; then
    # Model 3: Localnet — VMs connect directly to physical network via OVN localnet.
    # The NAD config "name" must match an existing OVN bridge-mapping on the nodes.
    # OVN-Kubernetes automatically creates "physnet:br-ex" on all nodes, so we use
    # "physnet" as the network name to reuse that default mapping (no NNCP needed).
    # The "subnets" field enables OVN-managed IPAM so VMs get IPs automatically.
    # attach-default-network=true keeps the pod network for control plane traffic
    # (ignition, API server, konnectivity) while the localnet interface provides
    # direct L2 connectivity for data plane features like EgressIP.
    oc apply -f - <<EOF
apiVersion: "k8s.cni.cncf.io/v1"
kind: NetworkAttachmentDefinition
metadata:
  name: localnet-network
  namespace: ${CLUSTER_NAMESPACE_PREFIX}-${CLUSTER_NAME}
spec:
  config: '{
      "cniVersion": "0.3.1",
      "name": "physnet",
      "type": "ovn-k8s-cni-overlay",
      "topology": "localnet",
      "netAttachDefName": "${CLUSTER_NAMESPACE_PREFIX}-${CLUSTER_NAME}/localnet-network",
      "subnets": "192.168.223.0/24"
  }'
EOF
    EXTRA_ARGS="${EXTRA_ARGS} --attach-default-network=true --additional-network name:${CLUSTER_NAMESPACE_PREFIX}-${CLUSTER_NAME}/localnet-network"
  elif [[ "${ATTACH_DEFAULT_NETWORK}" == "localnet-multi" ]]; then
    # Multi-Network Localnet Architecture:
    # VMs get LOCALNET_MULTI_NETWORK_COUNT localnet interfaces with --attach-default-network=false
    # (no pod network). enp1s0 → localnet-1 (physnet:br-ex) with default gateway and DNS.
    # enp2s0.. → localnet-2..N (physnet2..physnetN:br-ex) without gateway.
    # Guest OVN picks enp1s0 as br-ex (has default route) → EgressIP SNAT works natively.

    ns="${CLUSTER_NAMESPACE_PREFIX}-${CLUSTER_NAME}"
    NETWORK_COUNT="${LOCALNET_MULTI_NETWORK_COUNT:-2}"
    if [[ "${NETWORK_COUNT}" -lt 1 ]]; then
      echo "ERROR: LOCALNET_MULTI_NETWORK_COUNT must be at least 1"
      exit 1
    fi
    echo "Setting up ${NETWORK_COUNT} localnet networks (no pod network)..."

    # Discover OVN container names before first oc exec usage
    if [[ -z "${OVN_OVS_CONTAINER:-}" ]]; then
      # Get first ovnkube-node pod for container discovery
      discovery_pod=$(oc get pods -n openshift-ovn-kubernetes -l app=ovnkube-node -o jsonpath='{.items[0].metadata.name}')
      if ! discover_ovn_container_names "${discovery_pod}"; then
        echo "ERROR: Failed to discover OVN container names" >&2
        exit 1
      fi
    fi

    # Parse subnets from comma-separated LOCALNET_MULTI_SUBNETS into an array.
    # Format: "192.168.111.128/25,192.168.224.0/24,..." — first subnet gets default gateway.
    # On baremetal dev-scripts the primary subnet must not overlap management VIPs on br-ex
    # (ingress .4, api .5, node .20-.25, MetalLB/HC API .30-.32); default uses .128/25.
    IFS=',' read -ra SUBNETS <<< "${LOCALNET_MULTI_SUBNETS}"
    if [[ ${#SUBNETS[@]} -lt ${NETWORK_COUNT} ]]; then
      echo "ERROR: LOCALNET_MULTI_SUBNETS has ${#SUBNETS[@]} entries but LOCALNET_MULTI_NETWORK_COUNT=${NETWORK_COUNT}"
      exit 1
    fi

    # Add physnet2..physnetN bridge-mappings on all nodes.
    # The default physnet:br-ex exists automatically. Additional bridge-mapping names
    # (physnet2, physnet3, ...) are needed because OVN-K doesn't support multiple NADs
    # with different configs on the same NetConf.Name. All map to the same physical bridge br-ex.
    if [[ ${NETWORK_COUNT} -gt 1 ]]; then
      echo "Adding physnet2..physnet${NETWORK_COUNT} bridge-mappings on all nodes..."
      for NODE in $(oc get nodes -o jsonpath='{.items[*].metadata.name}'); do
        OVN_POD=$(oc get pods -n openshift-ovn-kubernetes -l app=ovnkube-node \
          --field-selector "spec.nodeName=${NODE}" -o jsonpath='{.items[0].metadata.name}')
        if [[ -z "${OVN_POD}" ]]; then
          echo "WARNING: No ovnkube-node pod found on node ${NODE}, skipping"
          continue
        fi
        CURRENT_MAPPINGS=$(oc exec -n openshift-ovn-kubernetes "${OVN_POD}" -c "${OVN_OVS_CONTAINER}" -- \
          ovs-vsctl get Open_vSwitch . external-ids:ovn-bridge-mappings 2>/dev/null | tr -d '"' || true)
        if [[ -z "${CURRENT_MAPPINGS}" ]]; then
          CURRENT_MAPPINGS="physnet:br-ex"
        fi
        NEW_MAPPINGS="${CURRENT_MAPPINGS}"
        for i in $(seq 2 "${NETWORK_COUNT}"); do
          if ! echo "${NEW_MAPPINGS}" | grep -q "physnet${i}:br-ex"; then
            NEW_MAPPINGS="${NEW_MAPPINGS},physnet${i}:br-ex"
          fi
        done
        if [[ "${NEW_MAPPINGS}" != "${CURRENT_MAPPINGS}" ]]; then
          oc exec -n openshift-ovn-kubernetes "${OVN_POD}" -c "${OVN_OVS_CONTAINER}" -- \
            ovs-vsctl set Open_vSwitch . external-ids:ovn-bridge-mappings="${NEW_MAPPINGS}" || true
          echo "Updated bridge-mappings on node ${NODE}: ${NEW_MAPPINGS}"
        else
          echo "Bridge-mappings already correct on node ${NODE}: ${CURRENT_MAPPINGS}"
        fi
      done

      # Verify bridge-mappings on all nodes
      echo "Verifying bridge-mappings on all nodes..."
      for NODE in $(oc get nodes -o jsonpath='{.items[*].metadata.name}'); do
        OVN_POD=$(oc get pods -n openshift-ovn-kubernetes -l app=ovnkube-node \
          --field-selector "spec.nodeName=${NODE}" -o jsonpath='{.items[0].metadata.name}')
        MAPPINGS=$(oc exec -n openshift-ovn-kubernetes "${OVN_POD}" -c "${OVN_OVS_CONTAINER}" -- \
          ovs-vsctl get Open_vSwitch . external-ids:ovn-bridge-mappings 2>/dev/null || true)
        echo "  ${NODE}: ${MAPPINGS}"
      done
    fi

    # Create localnet NADs: localnet-1 uses physnet, localnet-2 uses physnet2, etc.
    for i in $(seq 1 "${NETWORK_COUNT}"); do
      NAD_NAME="localnet-${i}"
      if [[ ${i} -eq 1 ]]; then
        PHYSNET_NAME="physnet"
      else
        PHYSNET_NAME="physnet${i}"
      fi
      SUBNET="${SUBNETS[$((i-1))]}"
      EXCLUDE_SUBNETS_JSON=""
      if [[ ${i} -eq 1 && -n "${LOCALNET_MULTI_EXCLUDE_SUBNETS:-}" ]]; then
        EXCLUDE_SUBNETS_JSON=",\"excludeSubnets\": \"${LOCALNET_MULTI_EXCLUDE_SUBNETS}\""
      fi
      oc apply -f - <<EOF
apiVersion: "k8s.cni.cncf.io/v1"
kind: NetworkAttachmentDefinition
metadata:
  name: ${NAD_NAME}
  namespace: ${ns}
spec:
  config: '{
      "cniVersion": "0.3.1",
      "name": "${PHYSNET_NAME}",
      "type": "ovn-k8s-cni-overlay",
      "topology": "localnet",
      "netAttachDefName": "${ns}/${NAD_NAME}",
      "subnets": "${SUBNET}"${EXCLUDE_SUBNETS_JSON}
  }'
EOF
      if [[ -n "${EXCLUDE_SUBNETS_JSON}" ]]; then
        echo "Created NAD ${NAD_NAME} (${PHYSNET_NAME}:br-ex, subnet ${SUBNET}, exclude ${LOCALNET_MULTI_EXCLUDE_SUBNETS})"
      else
        echo "Created NAD ${NAD_NAME} (${PHYSNET_NAME}:br-ex, subnet ${SUBNET})"
      fi
    done

    EXTRA_ARGS="${EXTRA_ARGS} --attach-default-network=false"
    for i in $(seq 1 "${NETWORK_COUNT}"); do
      EXTRA_ARGS="${EXTRA_ARGS} --additional-network name:${ns}/localnet-${i}"
    done
  else
    # Existing macvlan path
    oc apply -f - <<EOF
apiVersion: "k8s.cni.cncf.io/v1"
kind: NetworkAttachmentDefinition
metadata:
  name: macvlan-bridge-whereabouts
  namespace: ${CLUSTER_NAMESPACE_PREFIX}-${CLUSTER_NAME}
spec:
  config: '{
      "cniVersion": "0.3.1",
      "name": "whereabouts",
      "type": "macvlan",
      "master": "enp3s0",
      "mode": "bridge",
      "ipam": {
        "type": "whereabouts",
        "range": "192.168.221.0/24"
      }
  }'
EOF
    if [[ "${ATTACH_DEFAULT_NETWORK}" == "true" ]]; then
      EXTRA_ARGS="${EXTRA_ARGS} --attach-default-network=true --additional-network name:local-cluster-${CLUSTER_NAME}/macvlan-bridge-whereabouts"
    else
      EXTRA_ARGS="${EXTRA_ARGS} --attach-default-network=false --additional-network name:local-cluster-${CLUSTER_NAME}/macvlan-bridge-whereabouts"
    fi
  fi
fi

if [[ -f "${SHARED_DIR}/GPU_DEVICE_NAME" ]]; then
  EXTRA_ARGS="${EXTRA_ARGS} --host-device-name $(cat "${SHARED_DIR}/GPU_DEVICE_NAME"),count:2"
fi

EXTRA_ARGS="${EXTRA_ARGS} --network-type=${HYPERSHIFT_NETWORK_TYPE} "

if [[ $HYPERSHIFT_NP_AUTOREPAIR == "true" ]]; then
  EXTRA_ARGS="${EXTRA_ARGS} --auto-repair"
fi

case "${IP_STACK}" in
 "v4")
   EXTRA_ARGS="${EXTRA_ARGS} --service-cidr 172.32.0.0/16 --cluster-cidr 10.136.0.0/14 "
   ;;
 "v4v6")
   # Use explicit CIDRs with IPv4 first (primary) since --default-dual doesn't work for KubeVirt
   # Use non-conflicting IPv6 CIDRs (fd03::/48, fd04::/112) to avoid conflicts with management cluster
   EXTRA_ARGS="${EXTRA_ARGS} --cluster-cidr 10.132.0.0/14 --cluster-cidr fd03::/48 --service-cidr 172.31.0.0/16 --service-cidr fd04::/112 "
   ;;
 "v6v4")
   # Use explicit CIDRs with IPv6 first (primary) for v6v4 stack
   EXTRA_ARGS="${EXTRA_ARGS} --cluster-cidr fd03::/48 --cluster-cidr 10.132.0.0/14 --service-cidr fd04::/112 --service-cidr 172.31.0.0/16 "
   ;;
 "v6")
   EXTRA_ARGS="${EXTRA_ARGS} --cluster-cidr fd03::/48 --service-cidr fd04::/112 "
   ;;
esac

echo "$(date) Creating HyperShift guest cluster ${CLUSTER_NAME}"
# Workaround for: https://issues.redhat.com/browse/OCPBUGS-42867
if [[ $HYPERSHIFT_CREATE_CLUSTER_RENDER == "true" ]]; then

  RENDER_COMMAND="--render --render-sensitive"
  OCP_MINOR_VERSION=$(oc version | grep "Server Version" | cut -d '.' -f2)
  if [ "$OCP_MINOR_VERSION" -le "16" ]; then
      RENDER_COMMAND="--render"
  fi

  # shellcheck disable=SC2086
  "${HCP_CLI}" create cluster kubevirt ${EXTRA_ARGS} ${ICSP_COMMAND} \
    --name "${CLUSTER_NAME}" \
    --namespace "${CLUSTER_NAMESPACE_PREFIX}" \
    --node-pool-replicas "${HYPERSHIFT_NODE_COUNT}" \
    --memory "${HYPERSHIFT_NODE_MEMORY}Gi" \
    --cores "${HYPERSHIFT_NODE_CPU_CORES}" \
    --root-volume-size 64 \
    --release-image "${RELEASE_IMAGE}" \
    --pull-secret "${PULL_SECRET_PATH}" \
    --generate-ssh \
    --control-plane-availability-policy "${CONTROL_PLANE_AVAILABILITY}" \
    --infra-availability-policy "${INFRA_AVAILABILITY}" \
    ${RENDER_COMMAND} > "${SHARED_DIR}/hypershift_create_cluster_render.yaml"

  oc apply -f "${SHARED_DIR}/hypershift_create_cluster_render.yaml"
else
  # shellcheck disable=SC2086
  eval "${HCP_CLI} create cluster kubevirt ${EXTRA_ARGS} ${ICSP_COMMAND} \
    --name ${CLUSTER_NAME} \
    --namespace ${CLUSTER_NAMESPACE_PREFIX} \
    --node-pool-replicas ${HYPERSHIFT_NODE_COUNT} \
    --memory ${HYPERSHIFT_NODE_MEMORY}Gi \
    --cores ${HYPERSHIFT_NODE_CPU_CORES} \
    --root-volume-size 64 \
    --release-image ${RELEASE_IMAGE} \
    --pull-secret ${PULL_SECRET_PATH} \
    --generate-ssh \
    --control-plane-availability-policy ${CONTROL_PLANE_AVAILABILITY} \
    --infra-availability-policy ${INFRA_AVAILABILITY} $(support_np_skew)"
fi

# For localnet and localnet-multi, configure OVN DHCP BEFORE waiting for
# Available. The VMs boot as soon as the NodePool controller creates them, which
# is well before the control plane is Available. If DHCP options (including the
# default gateway) are not attached to the LSPs by then, the VMs get a lease
# with no gateway and cannot pull the MCD OS extension image — kubelet never
# starts and the node never joins.
if [[ "${ATTACH_DEFAULT_NETWORK}" == "localnet-multi" ]]; then
  MULTI_NAMESPACE="${CLUSTER_NAMESPACE_PREFIX}-${CLUSTER_NAME}"
  NETWORK_COUNT="${LOCALNET_MULTI_NETWORK_COUNT:-2}"
  IFS=',' read -ra SUBNETS <<< "${LOCALNET_MULTI_SUBNETS}"

  if [[ -z "${OVN_OVS_CONTAINER:-}" ]]; then
    discovery_pod=$(oc get pods -n openshift-ovn-kubernetes -l app=ovnkube-node -o jsonpath='{.items[0].metadata.name}')
    if ! discover_ovn_container_names "${discovery_pod}"; then
      echo "ERROR: Failed to discover OVN container names" >&2
      exit 1
    fi
  fi

  # Poll for virt-launcher pods and configure OVN DHCP on those worker nodes before
  # the VM's first DHCP request. Per-node ovn-nbctl works on standalone and INTERCONNECT modes.
  echo "Waiting for virt-launcher pods so we can configure OVN DHCP before VM first boot..."
  LAUNCHER_NODES=""
  for attempt in $(seq 1 120); do
    LAUNCHER_NODES=$(oc get pods -n "${MULTI_NAMESPACE}" -l kubevirt.io=virt-launcher \
      -o jsonpath='{range .items[*]}{.spec.nodeName}{" "}{end}' 2>/dev/null | tr ' ' '\n' | sort -u | tr '\n' ' ')
    LAUNCHER_COUNT=$(echo "${LAUNCHER_NODES}" | wc -w)
    if [[ ${LAUNCHER_COUNT} -ge ${HYPERSHIFT_NODE_COUNT} ]]; then
      echo "Found virt-launcher pods on ${LAUNCHER_COUNT} node(s) (attempt ${attempt})"
      break
    fi
    echo "Waiting for virt-launcher pods... (${LAUNCHER_COUNT}/${HYPERSHIFT_NODE_COUNT} nodes, attempt ${attempt}/120)"
    sleep 5
  done

  if [[ -z "${LAUNCHER_NODES// }" ]]; then
    echo "WARNING: No virt-launcher pods found after 10 minutes, configuring DHCP on all nodes"
  fi

  echo "Configuring early OVN DHCP for multi (${NETWORK_COUNT})-localnet interfaces..."
  DHCP_CONFIGURE_READY=false
  for attempt in $(seq 1 120); do
    if [[ -n "${LAUNCHER_NODES// }" ]]; then
      configure_localnet_multi_dhcp_on_nodes "${MULTI_NAMESPACE}" "${NETWORK_COUNT}" "${LAUNCHER_NODES}" || true
    else
      configure_localnet_multi_dhcp_on_nodes "${MULTI_NAMESPACE}" "${NETWORK_COUNT}" || true
    fi

    PRIMARY_CONFIGURED=$(count_configured_localnet_lsps_for_nad "${MULTI_NAMESPACE}" "localnet-1" "${SUBNETS[0]}")
    if [[ ${PRIMARY_CONFIGURED} -ge ${HYPERSHIFT_NODE_COUNT} ]]; then
      echo "Early OVN DHCP configuration complete for multi (${NETWORK_COUNT})-localnet interfaces"
      DHCP_CONFIGURE_READY=true
      break
    fi

    echo "Attempt ${attempt}/120: ${PRIMARY_CONFIGURED}/${HYPERSHIFT_NODE_COUNT} primary LSPs configured"
    if [[ ${attempt} -eq 120 ]]; then
      echo "ERROR: Failed to configure DHCP on all worker localnet LSPs after 10 minutes"
      exit 1
    fi
    sleep 5
  done
fi

echo "Waiting for cluster to become available"
oc wait --timeout=30m --for=condition=Available --namespace=${CLUSTER_NAMESPACE_PREFIX} "hostedcluster/${CLUSTER_NAME}"
echo "Cluster became available, creating kubeconfig"
$HCP_CLI create kubeconfig --namespace="${CLUSTER_NAMESPACE_PREFIX}" --name="${CLUSTER_NAME}" >"${SHARED_DIR}/nested_kubeconfig"

if [[ "${ATTACH_DEFAULT_NETWORK}" == "localnet-multi" ]]; then
  # After HC is Available and VMIs are Running, configure OVN DHCP on each worker node
  # and renew leases so enp1s0 gets the default gateway (no pod network fallback).
  ensure_localnet_multi_worker_networking "${MULTI_NAMESPACE}" "${NETWORK_COUNT}" || \
    echo "WARNING: post-Available localnet-multi worker networking setup encountered errors"
fi

# OVN-Kubernetes assigns IPs to localnet ports via IPAM but does not create
# DHCP_Options entries, so the VMs never receive the assigned IP via DHCP.
# This block creates DHCP options in each per-node nbdb and attaches them to
# the localnet logical switch ports so that OVN's built-in DHCP responder
# hands out the IPs to the VMs.
if [[ "${ATTACH_DEFAULT_NETWORK}" == "localnet" ]]; then
  LOCALNET_NAMESPACE="${CLUSTER_NAMESPACE_PREFIX}-${CLUSTER_NAME}"
  LOCALNET_SUBNET="192.168.223.0/24"

  # Discover OVN container names before first oc exec usage
  if [[ -z "${OVN_OVS_CONTAINER:-}" ]]; then
    # Get first ovnkube-node pod for container discovery
    discovery_pod=$(oc get pods -n openshift-ovn-kubernetes -l app=ovnkube-node -o jsonpath='{.items[0].metadata.name}')
    if ! discover_ovn_container_names "${discovery_pod}"; then
      echo "ERROR: Failed to discover OVN container names" >&2
      exit 1
    fi
  fi

  echo "Waiting for VMIs to be running..."
  for _ in $(seq 1 60); do
    RUNNING_COUNT=$(oc get vmi -n "${LOCALNET_NAMESPACE}" --no-headers 2>/dev/null \
      | grep -c Running || true)
    if [[ "${RUNNING_COUNT}" -ge "${HYPERSHIFT_NODE_COUNT}" ]]; then
      echo "All ${RUNNING_COUNT} VMIs are running"
      break
    fi
    echo "Waiting for VMIs... (${RUNNING_COUNT}/${HYPERSHIFT_NODE_COUNT} running)"
    sleep 10
  done

  echo "Configuring OVN DHCP for localnet interfaces..."
  for VMI in $(oc get vmi -n "${LOCALNET_NAMESPACE}" -o jsonpath='{.items[*].metadata.name}'); do
    NODE=$(oc get vmi -n "${LOCALNET_NAMESPACE}" "${VMI}" -o jsonpath='{.status.nodeName}')
    OVN_POD=$(oc get pods -n openshift-ovn-kubernetes -l app=ovnkube-node \
      --field-selector "spec.nodeName=${NODE}" -o jsonpath='{.items[0].metadata.name}')

    LSP_NAME=$(oc exec -n openshift-ovn-kubernetes "${OVN_POD}" -c "${OVN_NBDB_CONTAINER}" -- \
      ovn-nbctl --columns=name --bare find Logical_Switch_Port \
      "external_ids:k8s.ovn.org/topology=localnet" 2>/dev/null)

    if [[ -z "${LSP_NAME}" ]]; then
      echo "WARNING: No localnet LSP found on node ${NODE} for VMI ${VMI}"
      continue
    fi

    DHCP_UUID=$(oc exec -n openshift-ovn-kubernetes "${OVN_POD}" -c "${OVN_NBDB_CONTAINER}" -- \
      ovn-nbctl create DHCP_Options cidr="${LOCALNET_SUBNET}" \
      options='"lease_time"="3500" "router"="192.168.223.1" "server_id"="192.168.223.1" "server_mac"="c0:ff:ee:00:00:01"' \
      2>/dev/null)

    oc exec -n openshift-ovn-kubernetes "${OVN_POD}" -c "${OVN_NBDB_CONTAINER}" -- \
      ovn-nbctl lsp-set-dhcpv4-options "${LSP_NAME}" "${DHCP_UUID}" 2>/dev/null

    # Clear port security on the VM's localnet port so EgressIP-SNATed packets
    # can exit the management cluster's OVN. Without this, OVN drops packets
    # whose source IP is the EgressIP (not the VM's assigned localnet IP).
    oc exec -n openshift-ovn-kubernetes "${OVN_POD}" -c "${OVN_NBDB_CONTAINER}" -- \
      ovn-nbctl clear Logical_Switch_Port "${LSP_NAME}" port_security 2>/dev/null

    echo "Configured DHCP and cleared port security for VMI ${VMI} on node ${NODE}"
  done
  echo "OVN DHCP and port security configuration complete for localnet interfaces"

  # Enable IP forwarding on enp2s0 (the secondary/localnet NIC) inside each
  # hosted cluster VM. OVN multi-NIC EgressIP uses iptables SNAT to change the
  # source IP on enp2s0, but the de-SNATed return traffic needs to be forwarded
  # from enp2s0 back to ovn-k8s-mp0. Without forwarding enabled on enp2s0,
  # these return packets are silently dropped by the kernel.
  # OVN-Kubernetes only enables forwarding on interfaces it manages (br-ex,
  # ovn-k8s-mp0) but not on the secondary NIC.
  NESTED_KUBECONFIG="${SHARED_DIR}/nested_kubeconfig"
  if [[ -f "${NESTED_KUBECONFIG}" ]]; then
    echo "Waiting for OVN node pods to be ready in hosted cluster..."
    for _ in $(seq 1 60); do
      OVN_READY_COUNT=$(KUBECONFIG="${NESTED_KUBECONFIG}" oc get pods -n openshift-ovn-kubernetes \
        -l app=ovnkube-node --no-headers 2>/dev/null | grep -c Running || true)
      if [[ "${OVN_READY_COUNT}" -ge "${HYPERSHIFT_NODE_COUNT}" ]]; then
        echo "All ${OVN_READY_COUNT} OVN node pods are running"
        break
      fi
      echo "Waiting for OVN node pods... (${OVN_READY_COUNT}/${HYPERSHIFT_NODE_COUNT} running)"
      sleep 10
    done

    echo "Enabling IP forwarding on enp2s0 for all hosted cluster nodes..."
    for OVN_NODE_POD in $(KUBECONFIG="${NESTED_KUBECONFIG}" oc get pods -n openshift-ovn-kubernetes \
      -l app=ovnkube-node -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
      KUBECONFIG="${NESTED_KUBECONFIG}" oc exec -n openshift-ovn-kubernetes "${OVN_NODE_POD}" \
        -c "${OVN_OVS_CONTAINER}" -- sysctl -w net.ipv4.conf.enp2s0.forwarding=1 2>/dev/null || true
      echo "Enabled enp2s0 forwarding on ${OVN_NODE_POD}"
    done
    echo "IP forwarding configuration complete for hosted cluster nodes"
  else
    echo "WARNING: Nested kubeconfig not found at ${NESTED_KUBECONFIG}, skipping enp2s0 forwarding setup"
  fi

  # Deploy ip-echo on the management cluster with localnet NAD for EgressIP
  # source-IP verification. The ip-echo pod gets a localnet IP that is NOT in the
  # hosted cluster's OVN node address set, so EgressIP reroute + SNAT applies
  # to traffic going to it. Without this, traffic to hosted cluster node IPs
  # (including localnet IPs) is exempted from EgressIP by OVN priority 102 policy.
  #
  # The ip-echo pod is deployed in a dedicated namespace (not the HyperShift
  # control plane namespace) to prevent HyperShift's control plane operator from
  # garbage-collecting it during namespace reconciliation.
  IPECHO_NAMESPACE="egressip-ipecho-${CLUSTER_NAME}"
  echo "Deploying ip-echo in dedicated namespace ${IPECHO_NAMESPACE}..."
  oc create namespace "${IPECHO_NAMESPACE}" --dry-run=client -o yaml | oc apply -f -
  oc label ns "${IPECHO_NAMESPACE}" pod-security.kubernetes.io/enforce=privileged --overwrite 2>/dev/null || true

  # Create a localnet NAD in the ip-echo namespace (same config as the hosted cluster namespace)
  oc apply -f - <<IPECHO_NAD_EOF
apiVersion: "k8s.cni.cncf.io/v1"
kind: NetworkAttachmentDefinition
metadata:
  name: localnet-network
  namespace: ${IPECHO_NAMESPACE}
spec:
  config: '{
      "cniVersion": "0.3.1",
      "name": "physnet",
      "type": "ovn-k8s-cni-overlay",
      "topology": "localnet",
      "netAttachDefName": "${IPECHO_NAMESPACE}/localnet-network",
      "subnets": "192.168.223.0/24"
  }'
IPECHO_NAD_EOF

  oc apply -f - <<IPECHO_EOF
apiVersion: v1
kind: Pod
metadata:
  name: egressip-ipecho
  namespace: ${IPECHO_NAMESPACE}
  annotations:
    k8s.v1.cni.cncf.io/networks: localnet-network
spec:
  containers:
  - name: ip-echo
    image: quay.io/openshifttest/ip-echo:1.2.0
    ports:
    - containerPort: 80
      protocol: TCP
    securityContext:
      runAsUser: 0
  restartPolicy: Always
  tolerations:
  - operator: Exists
IPECHO_EOF

  echo "Waiting for ip-echo pod to be ready..."
  oc wait --for=condition=Ready pod/egressip-ipecho -n "${IPECHO_NAMESPACE}" --timeout=120s

  IPECHO_LOCALNET_IP=$(oc get pod egressip-ipecho -n "${IPECHO_NAMESPACE}" \
    -o jsonpath='{.metadata.annotations.k8s\.v1\.cni\.cncf\.io/network-status}' | \
    python3 -c "import sys,json; nets=json.loads(sys.stdin.read()); [print(n['ips'][0]) for n in nets if 'localnet' in n.get('name','')]")
  echo "ip-echo localnet IP: ${IPECHO_LOCALNET_IP}:80"
  echo "${IPECHO_LOCALNET_IP}:80" > "${SHARED_DIR}/kubevirt_ipecho_url"
elif [[ "${ATTACH_DEFAULT_NETWORK}" == "localnet-multi" ]]; then
  # OVN DHCP and lease renewal run in ensure_localnet_multi_worker_networking above.
  # Deploy ip-echo for EgressIP source-IP verification.
  IFS=',' read -ra SUBNETS <<< "${LOCALNET_MULTI_SUBNETS}"
  IPECHO_NAMESPACE="egressip-ipecho-${CLUSTER_NAME}"
  echo "Deploying ip-echo in dedicated namespace ${IPECHO_NAMESPACE}..."
  oc create namespace "${IPECHO_NAMESPACE}" --dry-run=client -o yaml | oc apply -f -
  oc label ns "${IPECHO_NAMESPACE}" pod-security.kubernetes.io/enforce=privileged --overwrite 2>/dev/null || true

  # Create a primary localnet NAD in the ip-echo namespace
  oc apply -f - <<IPECHO_NAD_EOF
apiVersion: "k8s.cni.cncf.io/v1"
kind: NetworkAttachmentDefinition
metadata:
  name: localnet-1
  namespace: ${IPECHO_NAMESPACE}
spec:
  config: '{
      "cniVersion": "0.3.1",
      "name": "physnet",
      "type": "ovn-k8s-cni-overlay",
      "topology": "localnet",
      "netAttachDefName": "${IPECHO_NAMESPACE}/localnet-1",
      "subnets": "${SUBNETS[0]}"
  }'
IPECHO_NAD_EOF

  oc apply -f - <<IPECHO_EOF
apiVersion: v1
kind: Pod
metadata:
  name: egressip-ipecho
  namespace: ${IPECHO_NAMESPACE}
  annotations:
    k8s.v1.cni.cncf.io/networks: localnet-1
spec:
  containers:
  - name: ip-echo
    image: quay.io/openshifttest/ip-echo:1.2.0
    ports:
    - containerPort: 80
      protocol: TCP
    securityContext:
      runAsUser: 0
  restartPolicy: Always
  tolerations:
  - operator: Exists
IPECHO_EOF

  echo "Waiting for ip-echo pod to be ready..."
  oc wait --for=condition=Ready pod/egressip-ipecho -n "${IPECHO_NAMESPACE}" --timeout=120s

  IPECHO_LOCALNET_IP=$(oc get pod egressip-ipecho -n "${IPECHO_NAMESPACE}" \
    -o jsonpath='{.metadata.annotations.k8s\.v1\.cni\.cncf\.io/network-status}' | \
    python3 -c "import sys,json; nets=json.loads(sys.stdin.read()); [print(n['ips'][0]) for n in nets if 'localnet' in n.get('name','')]")
  echo "ip-echo localnet IP: ${IPECHO_LOCALNET_IP}:80"
  echo "${IPECHO_LOCALNET_IP}:80" > "${SHARED_DIR}/kubevirt_ipecho_url"
fi

echo "${CLUSTER_NAME}" > "${SHARED_DIR}/cluster-name"