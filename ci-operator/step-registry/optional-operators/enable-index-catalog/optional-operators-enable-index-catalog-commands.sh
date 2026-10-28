#!/bin/bash

set -euo pipefail

INDEX_IMAGE="${MULTISTAGE_PARAM_OVERRIDE_INDEX_IMAGE:-${INDEX_IMAGE:-}}"

if [[ "${INSTALL_OPERATOR:-false}" == "true" ]]; then
  : "${INDEX_IMAGE:?INSTALL_OPERATOR requires INDEX_IMAGE or MULTISTAGE_PARAM_OVERRIDE_INDEX_IMAGE}"
  : "${PACKAGE_NAME:?INSTALL_OPERATOR requires PACKAGE_NAME}"
  : "${INSTALL_NAMESPACE:?INSTALL_OPERATOR requires INSTALL_NAMESPACE}"
  : "${OPERATOR_WORKLOAD:?INSTALL_OPERATOR requires OPERATOR_WORKLOAD (kind/name)}"
  if [[ -n "${OPERAND_MANIFEST:-}" ]]; then
    : "${OPERAND_WORKLOAD:?OPERAND_MANIFEST requires OPERAND_WORKLOAD (kind/name)}"
  fi
fi

if [[ -z "${INDEX_IMAGE}" ]]; then
  echo "INDEX_IMAGE is not set; leaving default redhat-operators catalog in place."
  exit 0
fi

CATALOGSOURCE_NAME="${CATALOGSOURCE_NAME:-cs-custom}"
CATALOGSOURCE_DISPLAY_NAME="${CATALOGSOURCE_DISPLAY_NAME:-Custom Operators Catalog}"
PACKAGE_NAME="${PACKAGE_NAME:-}"
DISABLE_REDHAT_OPERATORS="${DISABLE_REDHAT_OPERATORS:-true}"

echo "Using custom index image: ${INDEX_IMAGE}"
echo "CatalogSource name: ${CATALOGSOURCE_NAME}"

if test -s "${SHARED_DIR}/proxy-conf.sh"; then
  # shellcheck source=/dev/null
  source "${SHARED_DIR}/proxy-conf.sh"
fi

function run_command() {
  printf 'Running:'
  printf ' %q' "$@"
  printf '\n'
  "$@"
}

function mcp_config_name() {
  oc get mcp worker -o jsonpath='{.status.configuration.name}'
}

function wait_mcp_updated() {
  local previous_config="$1"
  local counter=0
  local mcp_json current_config updated updating degraded

  while [[ ${counter} -lt 1800 ]]; do
    sleep 20
    counter=$((counter + 20))

    mcp_json=$(oc get mcp worker -o json)
    current_config=$(jq -r '.status.configuration.name // ""' <<<"${mcp_json}")
    updated=$(jq -r '([.status.conditions[]? | select(.type == "Updated") | .status] | first) // "Unknown"' <<<"${mcp_json}")
    updating=$(jq -r '([.status.conditions[]? | select(.type == "Updating") | .status] | first) // "Unknown"' <<<"${mcp_json}")
    degraded=$(jq -r '([.status.conditions[]? | select(.type == "Degraded") | .status] | first) // "Unknown"' <<<"${mcp_json}")

    echo "waiting ${counter}s: config=${current_config} Updated=${updated} Updating=${updating} Degraded=${degraded}"

    if [[ "${current_config}" != "${previous_config}" \
      && "${updated}" == "True" \
      && "${updating}" == "False" \
      && "${degraded}" == "False" ]]; then
      echo "MCP worker applied a new healthy configuration"
      return 0
    fi

    # Pull-secret / ICSP can be a no-op (already applied). Do not wait the full timeout.
    if [[ "${current_config}" == "${previous_config}" \
      && "${updated}" == "True" \
      && "${updating}" == "False" \
      && "${degraded}" == "False" ]]; then

      if ! oc get secret pull-secret -n openshift-config-managed >/dev/null 2>&1; then
        echo "Pull secret not yet observed in openshift-config-managed; continue waiting"
      elif ! oc get imagecontentsourcepolicy mirror-set-custom-index >/dev/null 2>&1; then
        echo "ImageContentSourcePolicy mirror-set-custom-index not yet present; continue waiting"
      else
        echo "MCP worker configuration unchanged and applied resources observed; treating as already applied"
        return 0
      fi
    fi
  done

  echo "MCP worker rollout timed out"
  run_command oc get mcp,node,icsp
  run_command oc get mcp worker -o yaml
  run_command oc get icsp -o yaml
  return 1
}
function merge_pull_secret() {
  run_command oc extract secret/pull-secret -n openshift-config --confirm --to /tmp

  local new_dockerconfig="/tmp/new-dockerconfigjson"
  cp /tmp/.dockerconfigjson "${new_dockerconfig}"

  # Disable tracing while handling registry credentials.
  [[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
  set +x

  if [[ -f /var/run/vault/mirror-registry/registry_brew.json ]]; then
    local brew_user brew_password brew_auth
    brew_user=$(jq -r '.user' /var/run/vault/mirror-registry/registry_brew.json)
    brew_password=$(jq -r '.password' /var/run/vault/mirror-registry/registry_brew.json)
    brew_auth=$(echo -n "${brew_user}:${brew_password}" | base64 -w 0)
    jq --arg auth "${brew_auth}" '.auths["brew.registry.redhat.io"] = {"auth": $auth}' \
      "${new_dockerconfig}" > /tmp/dockerconfig.brew
    mv /tmp/dockerconfig.brew "${new_dockerconfig}"
  else
    echo "WARNING: brew registry credentials not found at registry_brew.json"
  fi

  if [[ -f /var/run/vault/mirror-registry/registry_stage.json ]]; then
    local stage_user stage_password stage_auth
    stage_user=$(jq -r '.user' /var/run/vault/mirror-registry/registry_stage.json)
    stage_password=$(jq -r '.password' /var/run/vault/mirror-registry/registry_stage.json)
    stage_auth=$(echo -n "${stage_user}:${stage_password}" | base64 -w 0)
    jq --arg auth "${stage_auth}" '.auths["registry.stage.redhat.io"] = {"auth": $auth}' \
      "${new_dockerconfig}" > /tmp/dockerconfig.stage
    mv /tmp/dockerconfig.stage "${new_dockerconfig}"
  else
    echo "WARNING: stage registry credentials not found at registry_stage.json"
  fi

  if [[ "${WAS_TRACING}" == "true" ]]; then
    set -x
  fi

  local previous_config
  previous_config=$(mcp_config_name)
  run_command oc set data secret/pull-secret -n openshift-config \
    "--from-file=.dockerconfigjson=${new_dockerconfig}"
  wait_mcp_updated "${previous_config}"
}

function apply_icsp() {
  local previous_config
  previous_config=$(mcp_config_name)
  cat <<EOF | oc apply -f -
apiVersion: operator.openshift.io/v1alpha1
kind: ImageContentSourcePolicy
metadata:
  name: mirror-set-custom-index
spec:
  repositoryDigestMirrors:
  - mirrors:
    - registry.stage.redhat.io
    source: registry.redhat.io
  - mirrors:
    - brew.registry.redhat.io
    source: registry.stage.redhat.io
  - mirrors:
    - brew.registry.redhat.io
    source: registry-proxy.engineering.redhat.com
EOF
  wait_mcp_updated "${previous_config}"
}

function disable_redhat_operators() {
  echo "Disabling default redhat-operators catalog"
  oc get operatorhub cluster -o json |
    jq '
      del(
        .metadata.managedFields,
        .metadata.creationTimestamp,
        .metadata.resourceVersion,
        .metadata.uid,
        .metadata.generation,
        .status
      )
      | .spec.sources = ((.spec.sources // [])
        | if any(.[]; .name == "redhat-operators")
          then map(if .name == "redhat-operators"
                   then .disabled = true
                   else .
                   end)
          else . + [{"name": "redhat-operators", "disabled": true}]
          end)
    ' |
    oc apply -f -
  oc delete catalogsource redhat-operators -n openshift-marketplace --ignore-not-found
}

function create_catalogsource() {
  oc delete catalogsource "${CATALOGSOURCE_NAME}" -n openshift-marketplace --ignore-not-found
  jq -n \
    --arg name "${CATALOGSOURCE_NAME}" \
    --arg display_name "${CATALOGSOURCE_DISPLAY_NAME}" \
    --arg image "${INDEX_IMAGE}" \
    '{
      apiVersion: "operators.coreos.com/v1alpha1",
      kind: "CatalogSource",
      metadata: {
        name: $name,
        namespace: "openshift-marketplace"
      },
      spec: {
        displayName: $display_name,
        grpcPodConfig: {
          extractContent: {
            cacheDir: "/tmp/cache",
            catalogDir: "/configs"
          }
        },
        publisher: "OpenShift QE",
        sourceType: "grpc",
        updateStrategy: {
          registryPoll: {
            interval: "15m"
          }
        },
        image: $image
      }
    }' |
    oc apply -f -

  echo "Waiting for CatalogSource ${CATALOGSOURCE_NAME} to become READY"
  if ! oc wait catalogsource/"${CATALOGSOURCE_NAME}" -n openshift-marketplace \
    --for=jsonpath='{.status.connectionState.lastObservedState}'=READY --timeout=300s; then
    echo "CatalogSource ${CATALOGSOURCE_NAME} did not become READY"
    run_command oc get catalogsource -n openshift-marketplace
    run_command oc -n openshift-marketplace get catalogsource "${CATALOGSOURCE_NAME}" -o yaml
    run_command oc -n openshift-marketplace get pods -l "olm.catalogSource=${CATALOGSOURCE_NAME}" -o yaml
    return 1
  fi
  echo "CatalogSource ${CATALOGSOURCE_NAME} is READY"
}

function get_package_manifest() {
  oc get packagemanifests -n openshift-marketplace -o json | jq -e \
    --arg package "${PACKAGE_NAME}" --arg source "${CATALOGSOURCE_NAME}" \
    '[.items[] | select(.metadata.name == $package and .status.catalogSource == $source
      and .status.catalogSourceNamespace == "openshift-marketplace")]
      | if length == 1 then .[0] else error("expected one package from the custom catalog") end'
}

function wait_for_packagemanifest() {
  if [[ -z "${PACKAGE_NAME}" ]]; then
    echo "PACKAGE_NAME is empty; skipping PackageManifest check"
    return 0
  fi

  local counter=0
  local source=""
  while [[ ${counter} -lt 300 ]]; do
    sleep 10
    counter=$((counter + 10))
    source=$(get_package_manifest 2>/dev/null | jq -r '.status.catalogSource' || true)
    echo "waiting ${counter}s: PackageManifest ${PACKAGE_NAME} catalogSource=${source}"
    if [[ "${source}" == "${CATALOGSOURCE_NAME}" ]]; then
      echo "PackageManifest ${PACKAGE_NAME} is served by ${CATALOGSOURCE_NAME}"
      return 0
    fi
  done

  echo "PackageManifest ${PACKAGE_NAME} is not from ${CATALOGSOURCE_NAME} (got '${source}')"
  run_command oc get packagemanifest "${PACKAGE_NAME}" -o yaml || true
  run_command oc get catalogsource -A
  return 1
}

# Older oc clients do not support oc wait --for=create.
function wait_for_workload() {
  local workload="$1" namespace="$2"
  local deadline=$((SECONDS + 180))
  while (( SECONDS < deadline )); do
    if oc get "${workload}" -n "${namespace}" --request-timeout=10s -o name; then
      return 0
    fi
    echo "Waiting for ${workload} to be created in ${namespace}"
    sleep 5
  done
  echo "Timed out waiting for ${workload} to be created in ${namespace}"
  return 1
}

# Installation is opt-in so existing catalog-only consumers keep their behavior.
function install_operator() {
  local namespace="${INSTALL_NAMESPACE}"
  local manifest channel csv installed_csv
  manifest=$(get_package_manifest)
  # Choose the head of the newest stable channel, never a preview channel.
  channel=$(jq -r '.status.channels[].name | select(test("^stable(-[0-9]+(\\.[0-9]+)*)?$"))' <<<"${manifest}" | sort -V | tail -n 1)
  if [[ -z "${channel}" ]]; then
    echo "No stable channel found for ${PACKAGE_NAME} in ${CATALOGSOURCE_NAME}"
    return 1
  fi
  csv=$(jq -er --arg channel "${channel}" '.status.channels[] | select(.name == $channel) | .currentCSV | select(length > 0)' <<<"${manifest}")
  echo "Installing ${PACKAGE_NAME}: channel=${channel}, CSV=${csv}"
  oc create namespace "${namespace}" --dry-run=client -o yaml | oc apply -f -
  oc label namespace "${namespace}" openshift.io/cluster-monitoring=true --overwrite
  cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: ${OPERATOR_GROUP_NAME:-${PACKAGE_NAME}}
  namespace: ${namespace}
spec:
  targetNamespaces:
  - ${namespace}
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${SUBSCRIPTION_NAME:-${PACKAGE_NAME}}
  namespace: ${namespace}
spec:
  name: ${PACKAGE_NAME}
  channel: ${channel}
  source: ${CATALOGSOURCE_NAME}
  sourceNamespace: openshift-marketplace
  startingCSV: ${csv}
  installPlanApproval: Automatic
EOF
  # Wait for OLM to resolve the subscription before waiting on its actual CSV.
  oc wait subscription/"${SUBSCRIPTION_NAME:-${PACKAGE_NAME}}" -n "${namespace}" \
    --for=jsonpath='{.status.installedCSV}' --timeout=600s
  installed_csv=$(oc get subscription "${SUBSCRIPTION_NAME:-${PACKAGE_NAME}}" -n "${namespace}" -o jsonpath='{.status.installedCSV}')
  oc wait clusterserviceversion/"${installed_csv}" -n "${namespace}" \
    --for=jsonpath='{.status.phase}'=Succeeded --timeout=300s
  wait_for_workload "${OPERATOR_WORKLOAD}" "${namespace}"
  oc rollout status "${OPERATOR_WORKLOAD}" -n "${namespace}" --timeout=300s
  if [[ -n "${OPERAND_MANIFEST:-}" ]]; then
    if [[ -n "${OPERAND_CRD:-}" ]]; then
      oc wait crd/"${OPERAND_CRD}" --for=condition=Established --timeout=60s
    fi
    printf '%s\n' "${OPERAND_MANIFEST}" | oc apply -f -
    wait_for_workload "${OPERAND_WORKLOAD}" "${OPERAND_NAMESPACE:-${namespace}}"
    oc rollout status "${OPERAND_WORKLOAD}" -n "${OPERAND_NAMESPACE:-${namespace}}" --timeout=300s
  fi
}

merge_pull_secret
apply_icsp
if [[ "${DISABLE_REDHAT_OPERATORS}" == "true" ]]; then
  disable_redhat_operators
fi
create_catalogsource
wait_for_packagemanifest

echo "${CATALOGSOURCE_NAME}" > "${SHARED_DIR}/custom-catalogsource-name"
echo "${INDEX_IMAGE}" > "${SHARED_DIR}/custom-index-image"
echo "Custom catalog ${CATALOGSOURCE_NAME} is ready for OLM tests."

if [[ "${INSTALL_OPERATOR:-false}" == "true" ]]; then
  install_operator
fi
