#! /bin/bash

set -e
set -u
set -o pipefail


if [[ -z ${MULTISTAGE_PARAM_OVERRIDE_LOGGING_BUNDLES} ]] ; then
  echo "MULTISTAGE_PARAM_OVERRIDE_LOGGING_BUNDLES is not set."
  exit 1
fi

if [[ -z ${MULTISTAGE_PARAM_OVERRIDE_LOGGING_TEST_VERSION} ]] ; then
  echo "MULTISTAGE_PARAM_OVERRIDE_LOGGING_TEST_VERSION is not set."
  exit 1
fi

function set_proxy () {
    if test -s "${SHARED_DIR}/proxy-conf.sh" ; then
        echo "setting the proxy"
        echo "source ${SHARED_DIR}/proxy-conf.sh"
        source "${SHARED_DIR}/proxy-conf.sh"
    else
        echo "no proxy setting."
    fi
}

function run_command() {
    local CMD="$1"
    echo "Running Command: ${CMD}"
    eval "${CMD}"
}


# create ICSP for connected env.
function create_icsp_connected () {

    run_command "oc delete imagecontentsourcepolicies.operator.openshift.io/brew-registry --ignore-not-found=true"

    image_version="${MULTISTAGE_PARAM_OVERRIDE_LOGGING_TEST_VERSION//./-}"
    cat <<EOF | oc apply -f -
    apiVersion: operator.openshift.io/v1alpha1
    kind: ImageContentSourcePolicy
    metadata:
      name: logging-registry
    spec:
      repositoryDigestMirrors:
      - source: registry.redhat.io/openshift-logging/cluster-logging-rhel9-operator
        mirrors:
        - quay.io/redhat-user-workloads/obs-logging-tenant/cluster-logging-operator-v$image_version
      - source: registry.redhat.io/openshift-logging/log-file-metric-exporter-rhel9
        mirrors:
        - quay.io/redhat-user-workloads/obs-logging-tenant/log-file-metric-exporter-v$image_version
      - source: registry.redhat.io/openshift-logging/eventrouter-rhel9
        mirrors:
        - quay.io/redhat-user-workloads/obs-logging-tenant/logging-eventrouter-v$image_version
      - source: registry.redhat.io/openshift-logging/vector-rhel9
        mirrors:
        - quay.io/redhat-user-workloads/obs-logging-tenant/logging-vector-v$image_version
      - source: registry.redhat.io/openshift-logging/cluster-logging-operator-bundle
        mirrors:
        - quay.io/redhat-user-workloads/obs-logging-tenant/cluster-logging-operator-bundle-v$image_version
      - source: registry.redhat.io/openshift-logging/loki-operator-bundle
        mirrors:
        - quay.io/redhat-user-workloads/obs-logging-tenant/loki-operator-bundle-v$image_version
      - source: registry.redhat.io/openshift-logging/loki-rhel9-operator
        mirrors:
        - quay.io/redhat-user-workloads/obs-logging-tenant/loki-operator-v$image_version
      - source: registry.redhat.io/openshift-logging/logging-loki-rhel9
        mirrors:
        - quay.io/redhat-user-workloads/obs-logging-tenant/logging-loki-v$image_version
      - source: registry.redhat.io/openshift-logging/lokistack-gateway-rhel9
        mirrors:
        - quay.io/redhat-user-workloads/obs-logging-tenant/lokistack-gateway-v$image_version
      - source: registry.redhat.io/openshift-logging/opa-openshift-rhel9
        mirrors:
        - quay.io/redhat-user-workloads/obs-logging-tenant/opa-openshift-v$image_version
EOF
}


create_namespace() {
    local name="$1"
    cat << EOF | oc apply -f -
    apiVersion: v1
    kind: Namespace
    metadata:
      labels:
        openshift.io/cluster-monitoring: "true"
        pod-security.kubernetes.io/audit: privileged
        pod-security.kubernetes.io/audit-version: latest
        pod-security.kubernetes.io/enforce: privileged
        pod-security.kubernetes.io/enforce-version: latest
        pod-security.kubernetes.io/warn: privileged
        pod-security.kubernetes.io/warn-version: latest
        security.openshift.io/scc.podSecurityLabelSync: "false"
      name: $name
EOF
    # run_command "oc label ns/$name pod-security.kubernetes.io/audit=privileged pod-security.kubernetes.io/enforce=privileged  pod-security.kubernetes.io/warn=privileged --overwrite"
}

install_operator() {
    local bundle="$1"
    local install_namespace="$2"

    cd /tmp
    local -i ret=0
    run_command "operator-sdk run bundle $bundle -n $install_namespace --timeout=5m" || ret=$?
    # sometimes the command fails, but the installation succeeds, here check the operator pod's status before failing the script
    if [ $ret -ne 0 ]; then
        sub=$(oc get sub -n $install_namespace -ojsonpath="{.items[].metadata.name}")
        if [[ -z $sub ]]; then
            echo "subscription is not created, installing operator failed"
            return 1
        else
            interval=30
            max_retries=10
            csv_name=""
            retry_count=0
            echo "Waiting for '$sub' installed CSV to be populated (max retries: $max_retries)..."
            while [[ -z "$csv_name" ]]; do
                if [[ "$retry_count" -ge "$max_retries" ]]; then
                    echo "Error: Maximum number of retries ($max_retries) exceeded. The installed CSV was not found."
                    return 1
                fi
                csv_name=$(oc -n $install_namespace get sub $sub -ojsonpath="{.status.installedCSV}" 2>/dev/null)
                if [[ -z "$csv_name" ]]; then
                    retry_count=$((retry_count + 1))
                    echo "Retry #$retry_count: No installed CSV found yet. Retrying in $interval seconds..."
                    sleep "$interval"
                fi
            done
            local -i exit_code=0
            run_command "oc wait --for=jsonpath='{.status.phase}'=Succeeded csv/$csv_name -n $install_namespace --timeout=5m" || exit_code=$?
            if [ $exit_code -ne 0 ]; then
                echo "install operator failed"
                run_command "oc get ns $install_namespace -oyaml"
                echo
                run_command "oc get pod -l app.kubernetes.io/managed-by=operator-lifecycle-manager -n $install_namespace -oyaml"
                echo
                run_command "oc get csv $csv_name -n $install_namespace -oyaml"
                echo
                run_command "oc get installplan -n $install_namespace -oyaml"
                return 1
            fi
        fi
    fi
}

# from OCP 4.15, the OLM is optional, details: https://issues.redhat.com/browse/OCPVE-634
# since OCP4.18, OLMv1 is a new capability: OperatorLifecycleManagerV1
function check_olm_capability(){
    # check if OLMv0 capability is added
    knownCaps=`oc get clusterversion version -o=jsonpath="{.status.capabilities.knownCapabilities}"`
    if [[ ${knownCaps} =~ "OperatorLifecycleManager\"," ]]; then
        echo "knownCapabilities contains OperatorLifecycleManagerv0"
        # check if OLMv0 capability enabled
        enabledCaps=`oc get clusterversion version -o=jsonpath="{.status.capabilities.enabledCapabilities}"`
          if [[ ! ${enabledCaps} =~ "OperatorLifecycleManager\"," ]]; then
              echo "OperatorLifecycleManagerv0 capability is not enabled, skip the following tests..."
              exit 0
          fi
    fi
}



set_proxy
run_command "oc whoami"
run_command "which oc && oc version -o yaml"
run_command "which operator-sdk && operator-sdk version"
create_icsp_connected
check_olm_capability

# Before installing operators, sleep 5m for ICSP to be applied
sleep 300

OLD_IFS=$IFS
IFS=','
for bundle in $MULTISTAGE_PARAM_OVERRIDE_LOGGING_BUNDLES; do
    case "$bundle" in
        *"loki-operator-bundle"*)
        create_namespace "openshift-operators-redhat"
        install_operator $bundle "openshift-operators-redhat"
        ;;
        *"cluster-logging-operator-bundle"*)
        create_namespace "openshift-logging"
        install_operator $bundle "openshift-logging"
        ;;
        *)
        echo "unkonw bundle $bundle"
        ;;
    esac
done
IFS=$OLD_IFS


#support hypershift config guest cluster's icsp
#oc get imagecontentsourcepolicy -oyaml > /tmp/mgmt_icsp.yaml && yq-go r /tmp/mgmt_icsp.yaml 'items[*].spec.repositoryDigestMirrors' -  | sed  '/---*/d' > ${SHARED_DIR}/mgmt_icsp.yaml

run_command "oc get cm -n openshift-config-managed"
echo
run_command "oc get secret -n openshift-operators-redhat"
