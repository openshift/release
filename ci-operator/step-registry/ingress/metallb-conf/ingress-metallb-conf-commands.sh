#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Installing MetalLB"

# Detect environment and configure IP range accordingly
METALLB_IP_START=""
METALLB_IP_END=""
ENVIRONMENT="unknown"

# Check if this is a vSphere static IP environment
if [[ -f "${SHARED_DIR}/subnets.json" ]]; then
  ENVIRONMENT="vsphere-static"
  echo "Detected vSphere static IP environment"

  # Get subnets configuration
  SUBNETS_CONFIG="${SHARED_DIR}/subnets.json"

  # Extract MetalLB IP range from indices #40-49 (10 IPs for MetalLB)
  # IP allocation in vSphere static clusters:
  # - #0-1: Network/Gateway (reserved)
  # - #2-3: API/Ingress VIPs
  # - #4-10: Bootstrap + Control-plane + Compute nodes
  # - #11-23: Available for other uses
  # - #24-31: IPAM pool for dynamic machines (/29)
  # - #32-39: Available
  # - #40-49: MetalLB IP pool (10 IPs)
  echo "Extracting MetalLB IP addresses from vSphere subnet (indices #40-49)..."

  # Calculate IPs from machineNetworkCidr (vsphere-elastic format)
  machine_network_cidr=$(jq -r '.spec.machineNetworkCidr' "${SUBNETS_CONFIG}")
  METALLB_IP_START=$(python3 -c "import ipaddress;print(ipaddress.IPv4Network('${machine_network_cidr}')[40])")
  METALLB_IP_END=$(python3 -c "import ipaddress;print(ipaddress.IPv4Network('${machine_network_cidr}')[49])")

  if [[ -z "${METALLB_IP_START}" ]] || [[ -z "${METALLB_IP_END}" ]] || [[ "${METALLB_IP_START}" == "null" ]] || [[ "${METALLB_IP_END}" == "null" ]]; then
      echo "ERROR: Failed to extract MetalLB IP range from subnets.json"
      echo "Machine network CIDR: ${machine_network_cidr}"
      echo "Attempting to read subnets.json:"
      cat "${SUBNETS_CONFIG}" || echo "Failed to read subnets.json"
      exit 1
  fi

  echo "MetalLB IP range from vSphere subnet: ${METALLB_IP_START}-${METALLB_IP_END}"

else
  # Default to baremetalds hardcoded IP range
  ENVIRONMENT="baremetalds"
  echo "Detected baremetalds environment (or default)"
  METALLB_IP_START="192.168.111.30"
  METALLB_IP_END="192.168.111.39"
  echo "Using hardcoded MetalLB IP range: ${METALLB_IP_START}-${METALLB_IP_END}"
fi

# Check if metallb-operator package exists in catalogs
echo "Checking for metallb-operator package in available catalogs..."
CATALOG_RETRIES=3
PACKAGE_EXISTS=false
for retry in $(seq 1 ${CATALOG_RETRIES}); do
  if oc get packagemanifest metallb-operator -n openshift-marketplace &>/dev/null; then
    PACKAGE_EXISTS=true
    echo "Found metallb-operator package in catalog"
    break
  fi
  echo "Retry ${retry}/${CATALOG_RETRIES}: metallb-operator not found, waiting for catalog sync..."
  sleep 10
done

if [[ "${PACKAGE_EXISTS}" == "false" ]]; then
  echo "metallb-operator not found in any catalog after ${CATALOG_RETRIES} retries"
  echo "This is expected for pre-release OpenShift versions"
  echo "Falling back to upstream MetalLB manifest-based installation"

  # Install upstream MetalLB
  METALLB_VERSION="${METALLB_VERSION:-v0.14.9}"
  echo "Installing upstream MetalLB ${METALLB_VERSION}"

  # Apply MetalLB manifests (creates namespace and service accounts)
  oc apply -f https://raw.githubusercontent.com/metallb/metallb/${METALLB_VERSION}/config/manifests/metallb-native.yaml

  # Grant privileged SCC to MetalLB service accounts
  echo "Granting privileged SCC to MetalLB service accounts..."
  oc adm policy add-scc-to-user privileged -z controller -n metallb-system
  oc adm policy add-scc-to-user privileged -z speaker -n metallb-system

  echo "Waiting for MetalLB controller deployment..."
  oc wait --for=condition=Available --timeout=5m -n metallb-system deployment/controller || {
    echo "Error: MetalLB controller deployment failed"
    oc get pods -n metallb-system
    exit 1
  }

  echo "Waiting for MetalLB speaker daemonset..."
  oc wait --for=jsonpath='{.status.numberReady}'=1 --timeout=5m -n metallb-system daemonset/speaker || {
    echo "Warning: MetalLB speaker daemonset not fully ready, checking status..."
    oc get daemonset -n metallb-system speaker
    oc get pods -n metallb-system
  }

  echo "Upstream MetalLB installed successfully"

else
  # Install using OLM operator
  echo "Installing MetalLB operator from catalog"

  # Create the metallb-system namespace
  oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: metallb-system
  labels:
    openshift.io/cluster-monitoring: "true"
EOF

  # Create OperatorGroup
  # Note: No targetNamespaces specified - MetalLB operator requires AllNamespaces install mode
  oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: metallb-operator
  namespace: metallb-system
spec: {}
EOF

  # Subscribe to MetalLB operator
  cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: metallb-operator
  namespace: metallb-system
spec:
  channel: stable
  installPlanApproval: Automatic
  name: metallb-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

  # Wait for MetalLB operator to be ready
  RETRIES=30
  CSV=
  for i in $(seq "${RETRIES}") max; do
    [[ "${i}" == "max" ]] && break
    sleep 30
    if [[ -z "${CSV}" ]]; then
      echo "[Retry ${i}/${RETRIES}] The subscription is not yet available. Trying to get it..."
      CSV=$(oc get subscription -n metallb-system metallb-operator -o jsonpath='{.status.installedCSV}' || true)
      continue
    fi

    if [[ $(oc get csv -n metallb-system ${CSV} -o jsonpath='{.status.phase}') == "Succeeded" ]]; then
      echo "MetalLB operator is deployed successfully"
      break
    fi
    echo "Try ${i}/${RETRIES}: MetalLB operator is not deployed yet. Checking again in 30 seconds"
  done

  if [[ "$i" == "max" ]]; then
    echo "Error: Failed to deploy MetalLB operator"
    echo
    echo "=== Debugging Information ==="
    echo "Subscription Status:"
    oc get subscription -n metallb-system metallb-operator -o yaml || true
    echo
    echo "All CSVs in metallb-system namespace:"
    oc get csv -n metallb-system || true
    echo
    echo "All Pods in metallb-system namespace:"
    oc get pods -n metallb-system || true
    echo

    if [[ -n "${CSV}" ]]; then
      echo "CSV '${CSV}' YAML:"
      oc get csv "${CSV}" -n metallb-system -o yaml || true
      echo
      echo "CSV '${CSV}' Describe:"
      oc describe csv "${CSV}" -n metallb-system || true
    else
      echo "CSV is empty - the subscription never reported an installed CSV"
      echo "This indicates the operator installation failed at the subscription level"
    fi
    exit 1
  fi

  echo "Successfully installed MetalLB operator"

  # Create MetalLB instance (only for OLM operator installation)
  echo "Creating MetalLB custom resource..."
  oc create -f - <<EOF
apiVersion: metallb.io/v1beta1
kind: MetalLB
metadata:
  name: metallb
  namespace: metallb-system
EOF

  # Wait for MetalLB to be ready
  echo "Waiting for MetalLB instance to be ready..."
  oc wait --for=condition=Available --timeout=5m -n metallb-system metallb/metallb
fi

# Configure MetalLB with environment-specific IP range
echo "Configuring MetalLB with IP range ${METALLB_IP_START}-${METALLB_IP_END} (${ENVIRONMENT})..."

# Create IPAddressPool
cat <<EOF | oc apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: ip-pool
  namespace: metallb-system
spec:
  autoAssign: true
  addresses:
  - ${METALLB_IP_START}-${METALLB_IP_END}
EOF

echo "Created IPAddressPool with IP range ${METALLB_IP_START}-${METALLB_IP_END}"

# Create L2Advertisement
oc create -f - <<EOF
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: ip-pool-l2
  namespace: metallb-system
spec:
  ipAddressPools:
  - ip-pool
EOF

echo "Created L2Advertisement for IP pool"

# Verify MetalLB resources
echo "Verifying MetalLB resources..."
if [[ "${PACKAGE_EXISTS}" == "true" ]]; then
  oc get metallb -n metallb-system
fi
oc get ipaddresspool -n metallb-system
oc get l2advertisement -n metallb-system

echo "MetalLB configuration completed successfully"
echo "Environment: ${ENVIRONMENT}"
echo "MetalLB IP pool: ${METALLB_IP_START}-${METALLB_IP_END}"