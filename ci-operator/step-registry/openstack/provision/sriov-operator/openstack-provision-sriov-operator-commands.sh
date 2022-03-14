#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

# For disconnected or otherwise unreachable environments, we want to
# have steps use an HTTP(S) proxy to reach the API server. This proxy
# configuration file should export HTTP_PROXY, HTTPS_PROXY, and NO_PROXY
# environment variables, as well as their lowercase equivalents (note
# that libcurl doesn't recognize the uppercase variables).
if test -f "${SHARED_DIR}/proxy-conf.sh"
then
	# shellcheck disable=SC1090
	source "${SHARED_DIR}/proxy-conf.sh"
fi
function wait_for_sriov_pods() {
    # Wait up to 15 minutes for SNO to be installed
    for _ in $(seq 1 90); do
        SNO_REPLICAS=$(oc get Deployment/sriov-network-operator -n openshift-sriov-network-operator -o jsonpath='{.status.readyReplicas}' || true)
        if [ "${SNO_REPLICAS}" == "1" ]; then
            FOUND_SNO=1
            break
        fi
        echo "Waiting for sriov-network-operator to be installed"
        sleep 10
    done

    if [ -n "${FOUND_SNO:-}" ] ; then
        # Wait for the pods to be started from the operator
        for _ in $(seq 1 24); do
            NOT_RUNNING_PODS=$(oc get pods --no-headers -n openshift-sriov-network-operator | grep -Pv "(Completed|Running)" | wc -l || true)
            if [ "${NOT_RUNNING_PODS}" == "0" ]; then
                OPERATOR_READY=true
                break
            fi
            echo "Waiting for sriov-network-operator pods to be started and running"
            sleep 10
        done
        if [ -n "${OPERATOR_READY:-}" ] ; then
            echo "sriov-network-operator pods were installed successfully"
            # Even if the pods are ready, we need to wait for the webhook server to be
            # actually started, which usually takes a few seconds.
            sleep 10
        else
            echo "sriov-network-operator pods were not installed after 4 minutes"
            oc get pods -n openshift-sriov-network-operator
            exit 1
        fi
    else
        echo "sriov-network-operator was not installed after 15 minutes"
        exit 1
    fi
}

oc_version=$(oc version | cut -d ' ' -f 3 | cut -d '.' -f1,2 | sed -n '2p')
case "${oc_version}" in
    # Remove 4.11 once it's GA
    4.11)
        echo "OpenShift 4.11 was detected"
        is_dev_version=1 ;;
    *) ;;
esac

if [ -n "${is_dev_version:-}" ]; then
    echo "The SR-IOV will be installed from Github using release-${oc_version} branch."
    git clone --branch release-${oc_version} https://github.com/openshift/sriov-network-operator /tmp/sriov-network-operator
    pushd /tmp/sriov-network-operator
    # Until https://github.com/openshift/sriov-network-operator/pull/613 merges
    cp manifests/stable/supported-nic-ids_v1_configmap.yaml deploy/configmap.yaml

    # We need to skip the bits where it tries to install Skopeo
    export SKIP_VAR_SET=1
    # We export the links of the images, since Skopeo can't be used in the CI container
    export SRIOV_CNI_IMAGE=quay.io/openshift/origin-sriov-cni:${oc_version}
    export SRIOV_INFINIBAND_CNI_IMAGE=quay.io/openshift/origin-sriov-infiniband-cni:${oc_version}
    export SRIOV_DEVICE_PLUGIN_IMAGE=quay.io/openshift/origin-sriov-network-device-plugin:${oc_version}
    export NETWORK_RESOURCES_INJECTOR_IMAGE=quay.io/openshift/origin-sriov-dp-admission-controller:${oc_version}
    export SRIOV_NETWORK_CONFIG_DAEMON_IMAGE=quay.io/openshift/origin-sriov-network-config-daemon:${oc_version}
    export SRIOV_NETWORK_WEBHOOK_IMAGE=quay.io/openshift/origin-sriov-network-webhook:${oc_version}
    export SRIOV_NETWORK_OPERATOR_IMAGE=quay.io/openshift/origin-sriov-network-operator:${oc_version}
    unset NAMESPACE
    # CLUSTER_TYPE is used by both openshift/release and the operator, so we need to unset it
    # to let the operator figure out which cluster type it is.
    unset CLUSTER_TYPE
    make deploy-setup
    popd
    wait_for_sriov_pods
else
    SNO_NAMESPACE=$(
        oc create -f - -o jsonpath='{.metadata.name}' <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-sriov-network-operator
  annotations:
    workload.openshift.io/allowed: management
EOF
    )
    echo "Created \"$SNO_NAMESPACE\" Namespace"
    
    SNO_OPERATORGROUP=$(
        oc create -f - -o jsonpath='{.metadata.name}' <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: sriov-network-operators
  namespace: openshift-sriov-network-operator
spec:
  targetNamespaces:
  - openshift-sriov-network-operator
EOF
    )
    echo "Created \"$SNO_OPERATORGROUP\" OperatorGroup"
    
    channel=$(oc version -o yaml | grep openshiftVersion | grep -o '[0-9]*[.][0-9]*' | head -1)
    SNO_SUBSCRIPTION=$(
        oc create -f - -o jsonpath='{.metadata.name}' <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: sriov-network-operator-subscription
  namespace: openshift-sriov-network-operator
spec:
  channel: "${channel}"
  name: sriov-network-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
    )
    echo "Created \"$SNO_SUBSCRIPTION\" Subscription"

    # Wait up to 15 minutes for SNO to be installed
    for _ in $(seq 1 90); do
        SNO_CSV=$(oc -n "${SNO_NAMESPACE}" get subscription "${SNO_SUBSCRIPTION}" -o jsonpath='{.status.installedCSV}' || true)
        if [ -n "$SNO_CSV" ]; then
            if [[ "$(oc -n "${SNO_NAMESPACE}" get csv "${SNO_CSV}" -o jsonpath='{.status.phase}')" == "Succeeded" ]]; then
                FOUND_SNO=1
                break
            fi
        fi
        echo "Waiting for sriov-network-operator to be installed"
        sleep 10
    done

    if [ -n "${FOUND_SNO:-}" ] ; then
        wait_for_sriov_pods
        echo "sriov-network-operator was installed successfully"
    else
        echo "sriov-network-operator was not installed after 15 minutes"
        exit 1
    fi
fi
