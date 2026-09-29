#!/usr/bin/env bash

set -euo pipefail

# Azure CLI does not consistently retry DNS and lower-level transport failures.
# Keep direct retries scoped to safe repeats. AKS and node-pool creates remain
# single-shot because repeating them after an ambiguous response is unsafe.
# BEGIN AZURE CLI RETRY HELPER
AZURE_CLI_TRANSIENT_ERROR_PATTERN='NameResolutionError|Temporary failure in name resolution|Name or service not known|Failed to resolve|Could not resolve host|requests\.exceptions\.(ConnectionError|ConnectTimeout|ReadTimeout)|urllib3\.exceptions\.(NewConnectionError|ConnectTimeoutError|ReadTimeoutError)|RemoteDisconnected|Connection (reset|aborted|refused)|connect(ion)?[^:]* timed out|Read timed out|TLS handshake timeout|network is unreachable'

run_az_with_retry() {
  local operation="$1"
  shift

  local max_attempts=4
  local delay=5
  local max_delay=20
  local attempt=1
  local rc=0
  local capture_dir
  capture_dir="$(mktemp -d)"

  while true; do
    : >"${capture_dir}/stdout"
    : >"${capture_dir}/stderr"

    if "$@" >"${capture_dir}/stdout" 2>"${capture_dir}/stderr"; then
      cat "${capture_dir}/stdout"
      if [[ -s "${capture_dir}/stderr" ]]; then
        printf 'Azure CLI %s completed with status 0; command diagnostics suppressed\n' "${operation}" >&2
      fi
      rm -rf "${capture_dir}"
      return 0
    else
      rc=$?
    fi

    # Keep failed output private: stdout must not satisfy a caller's command
    # substitution, while stderr is used only for quiet retry classification.

    if ((rc >= 128 && rc <= 192)); then
      print_az_cli_failure "${capture_dir}"
      printf 'Azure CLI %s ended with status %d\n' "${operation}" "${rc}" >&2
      rm -rf "${capture_dir}"
      return "${rc}"
    fi

    if ! grep -Eiq "${AZURE_CLI_TRANSIENT_ERROR_PATTERN}" "${capture_dir}/stderr"; then
      print_az_cli_failure "${capture_dir}"
      printf 'Azure CLI %s failed with non-retryable status %d\n' "${operation}" "${rc}" >&2
      rm -rf "${capture_dir}"
      return "${rc}"
    fi

    if ((attempt >= max_attempts)); then
      print_az_cli_failure "${capture_dir}"
      printf 'Azure CLI %s failed after %d attempts with transient status %d\n' "${operation}" "${max_attempts}" "${rc}" >&2
      rm -rf "${capture_dir}"
      return "${rc}"
    fi

    printf 'Azure CLI %s hit transient status %d (attempt %d/%d); retrying in %ds\n' "${operation}" "${rc}" "${attempt}" "${max_attempts}" "${delay}" >&2
    if sleep "${delay}"; then
      :
    else
      rc=$?
      print_az_cli_failure "${capture_dir}"
      printf 'Azure CLI %s retry wait ended with status %d\n' "${operation}" "${rc}" >&2
      rm -rf "${capture_dir}"
      return "${rc}"
    fi
    attempt=$((attempt + 1))
    delay=$((delay * 2))
    if ((delay > max_delay)); then
      delay="${max_delay}"
    fi
  done
}
# END AZURE CLI RETRY HELPER

print_az_cli_failure() {
  local capture_dir="$1"
  [[ -s "${capture_dir}/stdout" ]] && sed "s|${AZURE_AUTH_CLIENT_SECRET}|***REDACTED***|g" "${capture_dir}/stdout" >&2
  [[ -s "${capture_dir}/stderr" ]] && sed "s|${AZURE_AUTH_CLIENT_SECRET}|***REDACTED***|g" "${capture_dir}/stderr" >&2
  return 0
}

AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
if [[ "${USE_HYPERSHIFT_AZURE_CREDS}" == "true" ]]; then
    AZURE_AUTH_LOCATION="/etc/hypershift-ci-jobs-azurecreds/credentials.json"
fi
AZURE_AUTH_CLIENT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientId)"
AZURE_AUTH_CLIENT_SECRET="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientSecret)"
AZURE_AUTH_TENANT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .tenantId)"
AZURE_LOCATION="${HYPERSHIFT_AZURE_LOCATION:-${LEASED_RESOURCE}}"

MI_ARGS=""
if [[ "${AKS_USE_HYPERSHIFT_MI}" == "true" ]]; then
    HYPERSHIFT_MI_LOCATION="/etc/hypershift-ci-jobs-azurecreds/aks-mi-info.json"
    ASSIGN_IDENTITY="$(<"${HYPERSHIFT_MI_LOCATION}" jq -r .assignIdentity)"
    KUBELET_ASSIGN_IDENTITY="$(<"${HYPERSHIFT_MI_LOCATION}" jq -r .kubeletAssignIdentity)"

    MI_ARGS="--assign-identity ${ASSIGN_IDENTITY} --assign-kubelet-identity ${KUBELET_ASSIGN_IDENTITY}"
fi

if [[ "${ENABLE_NAP:-}" == "true" ]]; then
    echo "Upgrading azure-cli for NAP support"
    pip-3 install --user 'azure-cli>=2.75.0'
    export PATH="${HOME}/.local/bin:${PATH}"
fi

az --version
run_az_with_retry "login" az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none

set -x

RESOURCE_NAME_PREFIX="${NAMESPACE}-${UNIQUE_HASH}"

CLUSTER_AUTOSCALER_ARGS=""
if [[ "${ENABLE_CLUSTER_AUTOSCALER:-}" == "true" ]] && [[ "${ENABLE_NAP:-}" != "true" ]]; then
    CLUSTER_AUTOSCALER_ARGS=" --cluster-autoscaler-profile balance-similar-node-groups=true"
fi

CERT_ROTATION_ARGS=""
if [[ "${ENABLE_AKS_CERT_ROTATION:-}" == "true" ]]; then
    CERT_ROTATION_ARGS+=" --enable-secret-rotation"

    if [[ "${AKS_CERT_ROTATION_POLL_INTERVAL:-}" != "" ]]; then
        CERT_ROTATION_ARGS+=" --rotation-poll-interval ${AKS_CERT_ROTATION_POLL_INTERVAL}"
    fi
fi

echo "Creating resource group for the aks cluster"
RESOURCEGROUP="${RESOURCE_NAME_PREFIX}-aks-rg"
run_az_with_retry "resource group creation" az group create --name "$RESOURCEGROUP" --location "$AZURE_LOCATION"
echo "$RESOURCEGROUP" > "${SHARED_DIR}/resourcegroup_aks"

echo "Building up the aks create command"
CLUSTER="${RESOURCE_NAME_PREFIX}-aks-cluster"
# Save the management cluster name before creation so post steps can clean up
# a cluster when a later provisioning operation fails.
echo "$CLUSTER" > "${SHARED_DIR}/aks-cluster-name"
AKS_CREATE_COMMAND=(
    az aks create
    --name "$CLUSTER"
    --resource-group "$RESOURCEGROUP"
    --load-balancer-sku "$AKS_LB_SKU"
    --os-sku "$AKS_OS_SKU"
    "${CLUSTER_AUTOSCALER_ARGS:-}"
    "${CERT_ROTATION_ARGS:-}"
    "${MI_ARGS:-}"
    --location "$AZURE_LOCATION"
    --network-plugin azure
    --network-policy azure
    --max-pods 250
)

if [[ "${ENABLE_NAP:-}" == "true" ]]; then
    echo "NAP is enabled, adding --node-provisioning-mode Auto"
    AKS_CREATE_COMMAND+=(--node-provisioning-mode Auto)
fi

if [[ -n "$AKS_ADDONS" ]]; then
     AKS_CREATE_COMMAND+=(--enable-addons "$AKS_ADDONS")
fi

# Version prioritization: specific > latest > default
if [[ -n "$AKS_K8S_VERSION" ]]; then
    AKS_CREATE_COMMAND+=(--kubernetes-version "$AKS_K8S_VERSION")
elif [[ "$USE_LATEST_K8S_VERSION" == "true" ]]; then
    K8S_LATEST_VERSION=$(run_az_with_retry "AKS version lookup" az aks get-versions --location "${AZURE_LOCATION}" --output json --query 'max(orchestrators[?isPreview==`null`].orchestratorVersion)')
    AKS_CREATE_COMMAND+=(--kubernetes-version "$K8S_LATEST_VERSION")
fi

if [[ "$AKS_GENERATE_SSH_KEYS" == "true" ]]; then
    AKS_CREATE_COMMAND+=(--generate-ssh-keys)
fi

if [[ "$AKS_ENABLE_FIPS_IMAGE" == "true" ]]; then
    AKS_CREATE_COMMAND+=(--enable-fips-image)
fi

echo "Creating AKS cluster"
eval "${AKS_CREATE_COMMAND[*]}"

echo "Waiting for AKS cluster to be ready"
run_az_with_retry "AKS readiness wait" az aks wait --created --name "$CLUSTER" --resource-group "$RESOURCEGROUP" --interval 30

if [[ "${ENABLE_NAP:-}" == "true" ]]; then
    echo "NAP is enabled, skipping manual zone-specific node pool creation"
elif [[ -n "$AKS_ZONES" ]]; then
    echo "Creating zone-specific node pools"
    read -ra ZONE_ARRAY <<< "$AKS_ZONES"

    for zone in "${ZONE_ARRAY[@]}"; do
        echo "Creating node pool for zone $zone"
        NODEPOOL_NAME="npz${zone}"

        NODEPOOL_CMD=(
            az aks nodepool add
            --resource-group "$RESOURCEGROUP"
            --cluster-name "$CLUSTER"
            --name "$NODEPOOL_NAME"
            --zones "$zone"
            --max-pods 250
            --node-count "$((AKS_NODE_COUNT / ${#ZONE_ARRAY[@]}))"
        )

        if [[ -n "$AKS_NODE_VM_SIZE" ]]; then
            NODEPOOL_CMD+=(--node-vm-size "$AKS_NODE_VM_SIZE")
        fi

        if [[ "${ENABLE_CLUSTER_AUTOSCALER:-}" == "true" ]]; then
            NODEPOOL_CMD+=(--enable-cluster-autoscaler)

            if [[ "${AKS_CLUSTER_AUTOSCALER_MIN_NODES:-}" != "" ]]; then
                NODEPOOL_CMD+=(--min-count "$((AKS_CLUSTER_AUTOSCALER_MIN_NODES))")
            fi

            if [[ "${AKS_CLUSTER_AUTOSCALER_MAX_NODES:-}" != "" ]]; then
                NODEPOOL_CMD+=(--max-count "$((AKS_CLUSTER_AUTOSCALER_MAX_NODES))")
            fi
        fi

        echo "Executing node pool creation command for zone $zone"
        eval "${NODEPOOL_CMD[*]}"
    done
fi

echo "Saving cluster info"
# Keep this generic name for existing consumers. HyperShift workflows may later
# overwrite it with the hosted cluster name.
echo "$CLUSTER" > "${SHARED_DIR}/cluster-name"
if [[ $AKS_ADDONS == *azure-keyvault-secrets-provider* ]]; then
    run_az_with_retry "AKS cluster lookup" az aks show -n "$CLUSTER" -g "$RESOURCEGROUP" | jq .addonProfiles.azureKeyvaultSecretsProvider.identity.clientId -r > "${SHARED_DIR}/aks_keyvault_secrets_provider_client_id"
    # Grant MI required permissions to the KV which will be created in the same RG as the AKS cluster
    AKS_KV_SECRETS_PROVIDER_OBJECT_ID="$(run_az_with_retry "AKS cluster lookup" az aks show -n "$CLUSTER" -g "$RESOURCEGROUP" | jq .addonProfiles.azureKeyvaultSecretsProvider.identity.objectId -r)"
    echo "$AKS_KV_SECRETS_PROVIDER_OBJECT_ID" > "${SHARED_DIR}/kv-object-id"
fi

echo "Building up the aks get-credentials command"
AKS_GET_CREDS_COMMAND=(
    az aks get-credentials
    --name "$CLUSTER"
    --resource-group "$RESOURCEGROUP"
)

if [[ "$AKS_ENABLE_FIPS_IMAGE" == "true" ]]; then
    AKS_GET_CREDS_COMMAND+=(--overwrite-existing)
fi

echo "Getting kubeconfig to the AKS cluster"
# shellcheck disable=SC2034
KUBECONFIG="${SHARED_DIR}/kubeconfig"
run_az_with_retry "AKS credential retrieval" "${AKS_GET_CREDS_COMMAND[@]}"

if [[ "${ENABLE_NAP:-}" == "true" ]]; then
    echo "Configuring NAP Karpenter resources"

    # Build zone requirements from AKS_ZONES
    ZONE_VALUES=""
    if [[ -n "${AKS_ZONES:-}" ]]; then
        read -ra ZONE_ARRAY <<< "$AKS_ZONES"
        for zone in "${ZONE_ARRAY[@]}"; do
            ZONE_VALUES+="            - ${AZURE_LOCATION}-${zone}
"
        done
    fi

    NODEPOOL_YAML=$(cat <<EOF
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: default
spec:
  template:
    spec:
      expireAfter: Never
      nodeClassRef:
        apiVersion: karpenter.azure.com/v1beta1
        kind: AKSNodeClass
        name: default
      requirements:
        - key: kubernetes.io/arch
          operator: In
          values:
            - amd64
        - key: kubernetes.io/os
          operator: In
          values:
            - linux
        - key: karpenter.sh/capacity-type
          operator: In
          values:
            - on-demand
        - key: karpenter.azure.com/sku-family
          operator: In
          values:
            - "${NAP_SKU_FAMILY:-D}"
        - key: karpenter.azure.com/sku-cpu
          operator: In
          values:
            - "${NAP_SKU_CPU:-16}"
        - key: karpenter.azure.com/sku-version
          operator: In
          values:
            - "3"
            - "4"
            - "5"
            - "6"
$(if [[ -n "$ZONE_VALUES" ]]; then
cat <<ZONES
        - key: topology.kubernetes.io/zone
          operator: In
          values:
${ZONE_VALUES}
ZONES
fi)
  limits:
    cpu: "200"
  disruption:
    budgets:
      - nodes: "0"
EOF
)

    # Map AKS_OS_SKU to Karpenter imageFamily
    NAP_IMAGE_FAMILY="AzureLinux"
    if [[ "${AKS_OS_SKU}" == "Ubuntu" ]]; then
        NAP_IMAGE_FAMILY="Ubuntu"
    fi

    NODECLASS_YAML=$(cat <<EOF
apiVersion: karpenter.azure.com/v1beta1
kind: AKSNodeClass
metadata:
  name: default
spec:
  imageFamily: "${NAP_IMAGE_FAMILY}"
EOF
)

    echo "Applying Karpenter NodePool"
    echo "$NODEPOOL_YAML" | oc apply -f -

    echo "Applying Karpenter AKSNodeClass"
    echo "$NODECLASS_YAML" | oc apply -f -

    # Create placeholder pods to trigger NAP node provisioning.
    # Resource requests are set high enough to ensure one pod per D16-equivalent node.
    PLACEHOLDER_YAML=$(cat <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nap-placeholder
  namespace: default
spec:
  replicas: ${AKS_NODE_COUNT:-9}
  selector:
    matchLabels:
      app: nap-placeholder
  template:
    metadata:
      labels:
        app: nap-placeholder
    spec:
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels:
              app: nap-placeholder
      containers:
        - name: pause
          image: registry.k8s.io/pause:3.9
          resources:
            requests:
              cpu: "14"
              memory: "56Gi"
EOF
)

    echo "Creating placeholder deployment to trigger NAP node provisioning"
    echo "$PLACEHOLDER_YAML" | oc apply -f -

    collect_nap_artifacts() {
        echo "Collecting NAP artifacts"
        oc get nodepool.karpenter.sh -o yaml > "${ARTIFACT_DIR}/karpenter-nodepools.yaml" 2>&1 || true
        oc get aksnodeclass -o yaml > "${ARTIFACT_DIR}/karpenter-aksnodeclasses.yaml" 2>&1 || true
        oc get nodes -o custom-columns='NAME:.metadata.name,ZONE:.metadata.labels.topology\.kubernetes\.io/zone,INSTANCE-TYPE:.metadata.labels.node\.kubernetes\.io/instance-type,READY:.status.conditions[-1:].status' > "${ARTIFACT_DIR}/nap-node-zone-distribution.txt" 2>&1 || true

        echo "NAP node zone distribution:"
        cat "${ARTIFACT_DIR}/nap-node-zone-distribution.txt" 2>/dev/null || true
        echo "Zone summary:"
        awk 'NR>1 && $2 ~ /[a-z]+-[0-9]+$/ { zones[$2]++ } END { for (z in zones) printf "  %s: %d nodes\n", z, zones[z] }' "${ARTIFACT_DIR}/nap-node-zone-distribution.txt" 2>/dev/null || true
    }

    # BEGIN NAP FAILURE ARTIFACT COLLECTOR
    # Publish only fixed keys and allowlisted values. Cluster-provided strings stay in
    # the private temporary directory and are used only for in-memory categorization.
    collect_nap_failure_artifacts() {
        local xtrace_enabled=false
        local capture_dir=""
        local nodeclaims_available=false
        local karpenter_events_available=false
        local scheduler_events_available=false
        local metrics_available=false
        local nodeclaim_count=0
        local karpenter_event_count=0
        local scheduler_event_count=0
        local karpenter_warning_count=0
        local karpenter_normal_count=0
        local scheduler_warning_count=0
        local scheduler_normal_count=0
        local initialized_true=0
        local initialized_false=0
        local initialized_unknown=0
        local launched_true=0
        local launched_false=0
        local launched_unknown=0
        local ready_true=0
        local ready_false=0
        local ready_unknown=0
        local registered_true=0
        local registered_false=0
        local registered_unknown=0
        local quota_category=0
        local sku_unavailable_category=0
        local out_of_capacity_category=0
        local no_instance_type_category=0
        local scheduling_constraint_category=0
        local metrics=""
        local metrics_pattern=$'^([0-9]{1,4}\t){23}[0-9]{1,4}$'

        [[ $- == *x* ]] && xtrace_enabled=true
        set +x

        echo "Collecting NAP failure diagnostics"

        if capture_dir="$(mktemp -d 2>/dev/null)"; then
            if oc --request-timeout=15s get nodeclaims.karpenter.sh -o json \
                > "${capture_dir}/nodeclaims.json" 2>/dev/null \
                && jq -e '.items | type == "array"' "${capture_dir}/nodeclaims.json" >/dev/null 2>/dev/null; then
                nodeclaims_available=true
            else
                printf '{"items":[]}\n' > "${capture_dir}/nodeclaims.json"
            fi

            if oc --request-timeout=15s get events -A \
                --field-selector source=karpenter-events -o json \
                > "${capture_dir}/karpenter-events.json" 2>/dev/null \
                && jq -e '.items | type == "array"' "${capture_dir}/karpenter-events.json" >/dev/null 2>/dev/null; then
                karpenter_events_available=true
            else
                printf '{"items":[]}\n' > "${capture_dir}/karpenter-events.json"
            fi

            if oc --request-timeout=15s get events -n default \
                --field-selector involvedObject.kind=Pod -o json \
                > "${capture_dir}/scheduler-events.json" 2>/dev/null \
                && jq -e '.items | type == "array"' "${capture_dir}/scheduler-events.json" >/dev/null 2>/dev/null; then
                scheduler_events_available=true
            else
                printf '{"items":[]}\n' > "${capture_dir}/scheduler-events.json"
            fi

            # jq emits digits only. The shell validates the complete fixed-width tuple
            # before assigning it to allowlisted output keys.
            if metrics="$(jq -nr \
                --slurpfile nodeclaims "${capture_dir}/nodeclaims.json" \
                --slurpfile karpenter_events "${capture_dir}/karpenter-events.json" \
                --slurpfile scheduler_events "${capture_dir}/scheduler-events.json" '
                    def cap: if . > 9999 then 9999 else . end;
                    ($nodeclaims[0].items) as $nodeclaims |
                    ($karpenter_events[0].items) as $karpenter_events |
                    ($scheduler_events[0].items | map(select(
                        (((.involvedObject.name? | select(type == "string")) // "") | startswith("nap-placeholder-")) and
                        ([.reason?, .source.component?, .reportingController?]
                            | map(select(type == "string"))
                            | any(test("schedul"; "i")))
                    ))) as $scheduler_events |
                    (([$nodeclaims[]?.status.conditions[]? | .reason?, .message?] +
                      [$karpenter_events[]? | .reason?, .message?] +
                      [$scheduler_events[]? | .reason?, .message?])
                        | map(select(type == "string"))) as $diagnostic_text |
                    [
                        ($nodeclaims | length | cap),
                        ($karpenter_events | length | cap),
                        ($scheduler_events | length | cap),
                        ($karpenter_events | map(select(.type? == "Warning")) | length | cap),
                        ($karpenter_events | map(select(.type? == "Normal")) | length | cap),
                        ($scheduler_events | map(select(.type? == "Warning")) | length | cap),
                        ($scheduler_events | map(select(.type? == "Normal")) | length | cap),
                        ([ $nodeclaims[]?.status.conditions[]? | select(.type? == "Initialized" and .status? == "True") ] | length | cap),
                        ([ $nodeclaims[]?.status.conditions[]? | select(.type? == "Initialized" and .status? == "False") ] | length | cap),
                        ([ $nodeclaims[]?.status.conditions[]? | select(.type? == "Initialized" and .status? == "Unknown") ] | length | cap),
                        ([ $nodeclaims[]?.status.conditions[]? | select(.type? == "Launched" and .status? == "True") ] | length | cap),
                        ([ $nodeclaims[]?.status.conditions[]? | select(.type? == "Launched" and .status? == "False") ] | length | cap),
                        ([ $nodeclaims[]?.status.conditions[]? | select(.type? == "Launched" and .status? == "Unknown") ] | length | cap),
                        ([ $nodeclaims[]?.status.conditions[]? | select(.type? == "Ready" and .status? == "True") ] | length | cap),
                        ([ $nodeclaims[]?.status.conditions[]? | select(.type? == "Ready" and .status? == "False") ] | length | cap),
                        ([ $nodeclaims[]?.status.conditions[]? | select(.type? == "Ready" and .status? == "Unknown") ] | length | cap),
                        ([ $nodeclaims[]?.status.conditions[]? | select(.type? == "Registered" and .status? == "True") ] | length | cap),
                        ([ $nodeclaims[]?.status.conditions[]? | select(.type? == "Registered" and .status? == "False") ] | length | cap),
                        ([ $nodeclaims[]?.status.conditions[]? | select(.type? == "Registered" and .status? == "Unknown") ] | length | cap),
                        (if any($diagnostic_text[]?; test("quota|cores? limit"; "i")) then 1 else 0 end),
                        (if any($diagnostic_text[]?; test("(sku|vm size).*(not available|unavailable|unsupported|restricted)"; "i")) then 1 else 0 end),
                        (if any($diagnostic_text[]?; test("out of capacity|insufficient capacity|overconstrainedallocationrequest|allocation failed"; "i")) then 1 else 0 end),
                        (if any($diagnostic_text[]?; test("no (available |compatible )?instance( type)?|no instance.*satisf"; "i")) then 1 else 0 end),
                        (if any($diagnostic_text[]?; test("failedschedul|failed schedul|unschedulable|did not match|didn.t match|insufficient (cpu|memory)"; "i")) then 1 else 0 end)
                    ] | @tsv
                ' 2>/dev/null)" \
                && [[ "${metrics}" =~ ${metrics_pattern} ]]; then
                IFS=$'\t' read -r \
                    nodeclaim_count karpenter_event_count scheduler_event_count \
                    karpenter_warning_count karpenter_normal_count \
                    scheduler_warning_count scheduler_normal_count \
                    initialized_true initialized_false initialized_unknown \
                    launched_true launched_false launched_unknown \
                    ready_true ready_false ready_unknown \
                    registered_true registered_false registered_unknown \
                    quota_category sku_unavailable_category out_of_capacity_category \
                    no_instance_type_category scheduling_constraint_category <<< "${metrics}"
                metrics_available=true
            fi
        else
            capture_dir=""
            echo "NAP failure diagnostics unavailable"
        fi

        # Delete private captures before attempting the public artifact write. Artifact
        # storage is best-effort, and its path must never appear in the parent log.
        if [[ -n "${capture_dir}" ]]; then
            rm -rf -- "${capture_dir}" 2>/dev/null || true
            capture_dir=""
        fi

        if [[ -n "${ARTIFACT_DIR:-}" ]]; then
            {
                cat > "${ARTIFACT_DIR}/nap-failure-summary.txt" <<EOF
diagnostic_coverage=limited
metrics_available=${metrics_available}
nodeclaims_available=${nodeclaims_available}
karpenter_events_available=${karpenter_events_available}
scheduler_events_available=${scheduler_events_available}
nodeclaim_count=${nodeclaim_count}
karpenter_event_count=${karpenter_event_count}
scheduler_event_count=${scheduler_event_count}
karpenter_event_type_Warning_count=${karpenter_warning_count}
karpenter_event_type_Normal_count=${karpenter_normal_count}
scheduler_event_type_Warning_count=${scheduler_warning_count}
scheduler_event_type_Normal_count=${scheduler_normal_count}
condition_Initialized_True_count=${initialized_true}
condition_Initialized_False_count=${initialized_false}
condition_Initialized_Unknown_count=${initialized_unknown}
condition_Launched_True_count=${launched_true}
condition_Launched_False_count=${launched_false}
condition_Launched_Unknown_count=${launched_unknown}
condition_Ready_True_count=${ready_true}
condition_Ready_False_count=${ready_false}
condition_Ready_Unknown_count=${ready_unknown}
condition_Registered_True_count=${registered_true}
condition_Registered_False_count=${registered_false}
condition_Registered_Unknown_count=${registered_unknown}
category_quota=${quota_category}
category_sku_unavailable=${sku_unavailable_category}
category_out_of_capacity=${out_of_capacity_category}
category_no_instance_type=${no_instance_type_category}
category_scheduling_constraint=${scheduling_constraint_category}
EOF
            } 2>/dev/null || {
                rm -f -- "${ARTIFACT_DIR}/nap-failure-summary.txt" 2>/dev/null || true
            }
        fi

        if [[ "${xtrace_enabled}" == "true" ]]; then
            set -x
        fi
        return 0
    }
    # END NAP FAILURE ARTIFACT COLLECTOR

    echo "Waiting for NAP to provision nodes"
    # Wait for the desired number of Ready nodes (NAP-provisioned + system pool)
    DESIRED_NODES=$((${AKS_NODE_COUNT:-9} + 3))
    NAP_TIMEOUT=600
    NAP_ELAPSED=0
    while true; do
        READY_NODES=$(oc get nodes --no-headers 2>/dev/null | grep -c " Ready" || true)
        if [[ "$READY_NODES" -ge "$DESIRED_NODES" ]]; then
            echo "All $DESIRED_NODES nodes are ready"
            break
        fi
        if [[ "$NAP_ELAPSED" -ge "$NAP_TIMEOUT" ]]; then
            echo "ERROR: Timed out waiting for NAP nodes. Only $READY_NODES/$DESIRED_NODES ready."
            oc get nodes || true
            oc get nodepool.karpenter.sh -o yaml || true
            collect_nap_artifacts
            collect_nap_failure_artifacts
            exit 1
        fi
        echo "Waiting for NAP nodes: $READY_NODES/$DESIRED_NODES ready (${NAP_ELAPSED}s/${NAP_TIMEOUT}s)..."
        sleep 30
        NAP_ELAPSED=$((NAP_ELAPSED + 30))
    done

    # Wait for zone labels to propagate on NAP nodes.
    # Karpenter-provisioned nodes are named aks-default-* while system pool
    # nodes are aks-nodepool1-*.  Zone labels may not be present immediately
    # after a node reaches Ready.
    echo "Waiting for zone labels on NAP nodes"
    ZONE_TIMEOUT=120
    ZONE_ELAPSED=0
    while true; do
        UNLABELED=$(oc get nodes --no-headers -o custom-columns='NAME:.metadata.name,ZONE:.metadata.labels.topology\.kubernetes\.io/zone' 2>/dev/null \
            | awk '/^aks-default-/ && $2 == "<none>" { count++ } END { print count+0 }')
        if [[ "$UNLABELED" -eq 0 ]]; then
            echo "All NAP nodes have zone labels"
            break
        fi
        if [[ "$ZONE_ELAPSED" -ge "$ZONE_TIMEOUT" ]]; then
            echo "WARNING: $UNLABELED NAP node(s) still missing zone labels after ${ZONE_TIMEOUT}s"
            break
        fi
        echo "Waiting for zone labels: $UNLABELED NAP node(s) without zone label (${ZONE_ELAPSED}s/${ZONE_TIMEOUT}s)..."
        sleep 10
        ZONE_ELAPSED=$((ZONE_ELAPSED + 10))
    done

    collect_nap_artifacts

    echo "Cleaning up placeholder deployment"
    oc delete deployment nap-placeholder -n default --ignore-not-found
fi

oc get nodes
oc version
