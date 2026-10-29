#!/usr/bin/env bash

set -euxo pipefail

function check_ho_version() {
    local ho_version
    local ho_version_major
    local ho_version_minor

    ho_version=$(oc get cm -n hypershift supported-versions -o jsonpath='{.data.supported-versions}' | jq -r '.versions[]' | sort -r | head -n 1)
    ho_version_major=$(cut -d . -f 1 <<< "$ho_version")
    if (( ho_version_major != 4 )); then
        echo "Expect HO major version to be 4 but found $ho_version_major, exiting" >&2
        exit 1
    fi
    ho_version_minor=$(cut -d . -f 2 <<< "$ho_version")
    if (( ho_version_minor < 18 )); then
        echo "HO minor version = $ho_version_minor < 18, skipping step"
        exit 0
    fi
}

# Timestamp
export PS4='[$(date "+%Y-%m-%d %H:%M:%S")] '

# Check HO version, skip step if unsupported
check_ho_version

# Error out if the CP is not highly available
cp_availability="$(oc get hc -A -o jsonpath='{.items[0].spec.controllerAvailabilityPolicy}')"
if [[ $cp_availability != "HighlyAvailable" ]]; then
    echo "Controller availability = $cp_availability != HighlyAvailable, cannot run etcd recovery test" >&2
    exit 1
fi

# Get cluster info
hc_name="$(oc get hc -A -o jsonpath='{.items[0].metadata.name}')"
etcd_replicas="$(oc get sts -n clusters-"${hc_name}" etcd -o jsonpath='{.spec.replicas}')"
etcd_generation="$(oc get sts -n clusters-"${hc_name}" etcd -o jsonpath='{.metadata.generation}')"

# Health check before disruption
KUBECONFIG="${SHARED_DIR}/nested_kubeconfig" oc wait nodes --all --for=condition=Ready=True --timeout=2m
KUBECONFIG="${SHARED_DIR}/nested_kubeconfig" oc wait co --all --for=condition=Available=True --timeout=2m
KUBECONFIG="${SHARED_DIR}/nested_kubeconfig" oc wait co --all --for=condition=Progressing=False --timeout=2m
KUBECONFIG="${SHARED_DIR}/nested_kubeconfig" oc wait co --all --for=condition=Degraded=False --timeout=2m
oc wait sts -n clusters-"${hc_name}" etcd --for=jsonpath='{.status.observedGeneration}'="$etcd_generation" --timeout=0
oc wait sts -n clusters-"${hc_name}" etcd --for=jsonpath='{.status.availableReplicas}'="$etcd_replicas" --timeout=0
oc wait sts -n clusters-"${hc_name}" etcd --for=jsonpath='{.status.currentReplicas}'="$etcd_replicas" --timeout=0
oc wait sts -n clusters-"${hc_name}" etcd --for=jsonpath='{.status.readyReplicas}'="$etcd_replicas" --timeout=0
oc wait sts -n clusters-"${hc_name}" etcd --for=jsonpath='{.status.replicas}'="$etcd_replicas" --timeout=0
oc wait sts -n clusters-"${hc_name}" etcd --for=jsonpath='{.status.updatedReplicas}'="$etcd_replicas" --timeout=0

# Corrupt member data
until oc rsh -n clusters-"${hc_name}" -c etcd etcd-0 rm -rf /var/lib/data/member; do
    echo "Failed to corrupt etcd member data. Retrying ..."
    sleep 10
done

# Wait for status changes
oc wait pods -n clusters-"${hc_name}" etcd-0 --for=condition=Ready=False --timeout=120s
oc wait hc -n clusters "${hc_name}" --for=condition=EtcdRecoveryActive=True --timeout=120s

# Wait for etcd recovery
oc wait hc -n clusters "${hc_name}" --for=condition=EtcdRecoveryActive=False --timeout=300s
oc wait hc -n clusters "${hc_name}" --for='jsonpath={.status.conditions[?(@.type=="EtcdRecoveryActive")].reason}'=AsExpected --timeout=0
oc wait pods -n clusters-"${hc_name}" etcd-0 --for=condition=Ready=True --timeout=180s
oc wait pods -n clusters-"${hc_name}" etcd-0 --for=jsonpath="{status.phase}"=Running --timeout=180s

# Health check after disruption
etcd_generation="$(oc get sts -n clusters-"${hc_name}" etcd -o jsonpath='{.metadata.generation}')"
oc wait sts -n clusters-"${hc_name}" etcd --for=jsonpath='{.status.observedGeneration}'="$etcd_generation" --timeout=120s
oc wait sts -n clusters-"${hc_name}" etcd --for=jsonpath='{.status.availableReplicas}'="$etcd_replicas" --timeout=120s
oc wait sts -n clusters-"${hc_name}" etcd --for=jsonpath='{.status.currentReplicas}'="$etcd_replicas" --timeout=120s
oc wait sts -n clusters-"${hc_name}" etcd --for=jsonpath='{.status.readyReplicas}'="$etcd_replicas" --timeout=120s
oc wait sts -n clusters-"${hc_name}" etcd --for=jsonpath='{.status.replicas}'="$etcd_replicas" --timeout=120s
oc wait sts -n clusters-"${hc_name}" etcd --for=jsonpath='{.status.updatedReplicas}'="$etcd_replicas" --timeout=120s
KUBECONFIG="${SHARED_DIR}/nested_kubeconfig" oc wait nodes --all --for=condition=Ready=True --timeout=120s
KUBECONFIG="${SHARED_DIR}/nested_kubeconfig" oc wait co --all --for=condition=Available=True --timeout=120s
KUBECONFIG="${SHARED_DIR}/nested_kubeconfig" oc wait co --all --for=condition=Progressing=False --timeout=120s
KUBECONFIG="${SHARED_DIR}/nested_kubeconfig" oc wait co --all --for=condition=Degraded=False --timeout=120s
