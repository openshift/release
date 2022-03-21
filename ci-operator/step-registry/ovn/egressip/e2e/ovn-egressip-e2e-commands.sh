#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

SOURCE_NAMESPACE="egressip-source"
TARGET_NAMESPACE="egressip-target"
EGRESSIP_NAME="egressip-source"
SOURCE_LABEL="node-role.kubernetes.io/egressip-test-source"
# TARGET_LABEL="node-role.kubernetes.io/egressip-test-target"
# TARGET_TAINT="egressip-test-target"
# EGRESS_ASSIGNABLE_LABEL="k8s.ovn.org/egress-assignable"
# https://docs.openshift.com/container-platform/4.10/installing/installing_aws/installing-restricted-networks-aws.html#installation-cloudformation-security_installing-restricted-networks-aws
TARGET_PORT="32767"

is_command() {
  local cmd="$1"
  if ! command -v ${cmd} &> /dev/null
  then
    echo "Command '${cmd} could not be found"
    exit 1
  fi
}

for cmd in wc jq oc mktemp nmap curl; do
  is_command $cmd
done

ingress_domain=$(oc get -n openshift-ingress-operator IngressController default -o jsonpath="{ .status.domain}")

################################################################
# Deploy egress IP source
################################################################

file=$(mktemp)
cat <<EOF >| $file
---
apiVersion: v1
kind: Namespace
metadata:
  name: ${SOURCE_NAMESPACE}
  labels:
    env: ${SOURCE_NAMESPACE}
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  labels:
    app: ${SOURCE_NAMESPACE}-route
  name: ${SOURCE_NAMESPACE}-route
  namespace: ${SOURCE_NAMESPACE}
spec:
  host: ${SOURCE_NAMESPACE}.${ingress_domain}
  port:
    targetPort: 8000
  to:
    kind: Service
    name: ${SOURCE_NAMESPACE}-service
    weight: 100
  wildcardPolicy: None
---
apiVersion: v1
kind: Service
metadata:
  name: ${SOURCE_NAMESPACE}-service
  namespace: ${SOURCE_NAMESPACE}
  labels:
    app: ${SOURCE_NAMESPACE}-service
spec:
  selector:
    app: ${SOURCE_NAMESPACE}-deployment
  ports:
    - protocol: TCP
      port: 8000
      targetPort: 8000
---
apiVersion: apps/v1
kind: Deployment
metadata:
  labels:
    app: ${SOURCE_NAMESPACE}-deployment
  name: ${SOURCE_NAMESPACE}-deployment
  namespace: ${SOURCE_NAMESPACE}
spec:
  replicas: 2
  selector:
    matchLabels:
      app: ${SOURCE_NAMESPACE}-deployment
  template:
    metadata:
      labels:
        app: ${SOURCE_NAMESPACE}-deployment
    spec:
      nodeSelector:
        ${SOURCE_LABEL}: ""
      containers:
      - command:
        - "/agnhost"
        - "netexec"
        - "--http-port"
        - "8000"
          #- serve-hostname
        image: k8s.gcr.io/e2e-test-images/agnhost:2.33
        imagePullPolicy: IfNotPresent
        name: agnhost
EOF
cat ${file}
oc apply -f ${file}

################################################################
# Assign egress IPs
################################################################

# Enumerate all IPs inside the subnet with nmap.
# For each IP, check if it is already taken (query cloudprivateipconfigs API resource).
# Return the first free IP.
# In case of failure, return string "failure".
get_first_free_ip(){
  local subnet="$1"
  local subnet_ips
  subnet_ips=$(nmap -n -sL ${subnet} | awk '/Nmap scan report/{print $NF}')
  local max
  max=$(echo $subnet_ips | wc -w)
  local i
  i=0
  # for amazon, skp the first 5 addresses
  # https://stackoverflow.com/questions/64212709/how-do-i-assign-an-ec2-instance-to-a-fixed-ip-address-within-a-subnet
  for ip in ${subnet_ips}; do
    i=$((i+1))
    if [ ${i} -le 5 ] || [ $i -ge ${max} ]; then
      continue
    fi
    if oc get cloudprivateipconfigs | grep -q ${ip} ; then
      continue
    fi
    echo ${ip}
    return
  done

  echo "failure"
  return
}

echo "Creating a minimum of 2, and up to n number of EgressIPs, where n = count(nodes)"
nodes=$(oc get nodes -l ${SOURCE_LABEL}= -o name)
if [ "$(echo $nodes | wc -w)" -lt 2 ] ; then
  echo "Not enough worker nodes with label ${SOURCE_LABEL} - at least 2 worker nodes are required. Got: $nodes"
  exit 1
fi

egress_ip_list=""
for n in $nodes; do
  egress_ipconfig=$(oc get $n -o jsonpath="{ .metadata.annotations.cloud\.network\.openshift\.io/egress-ipconfig }")
  if [ "${egress_ipconfig}" == "" ]; then
    echo "Node $n egress-ipconfig annotation is empty. Skipping the node"
    continue
  fi
  ipv4_range=$(echo "${egress_ipconfig}" | jq -r '.[0].ifaddr.ipv4')
  if [ "${ipv4_range}" != "null" ]; then
    free_ip=$(get_first_free_ip "${ipv4_range}")
    if [ "$free_ip" == "failure" ]; then
      echo "Could not find a free IP in subnet ${ipv4_range}. Skipping the node subnet."
    else
      egress_ip_list="${egress_ip_list} $free_ip"
    fi
  fi
  ipv6_range=$(echo "${egress_ipconfig}" | jq -r '.[0].ifaddr.ipv6')
  if [ "${ipv6_range}" != "null" ]; then
    free_ip=$(get_first_free_ip "${ipv6_range}")
    if [ "$free_ip" == "failure" ]; then
      echo "Could not find a free IP in subnet ${ipv6_range}. Skipping the node subnet."
    else
      egress_ip_list="${egress_ip_list} $free_ip"
    fi
  fi
done

if [ "${egress_ip_list}" == "" ]; then
  echo "Empty EgressIP list. Exiting with error."
  exit 1
fi

egressips=""
for eip in ${egress_ip_list}; do
  egressips="${egressips}\n  - $eip"
done

file=$(mktemp)
cat <<EOF >| ${file}
apiVersion: k8s.ovn.org/v1
kind: EgressIP
metadata:
  name: ${EGRESSIP_NAME}
spec:
  egressIPs: $(echo -e "${egressips}")
  namespaceSelector:
    matchLabels:
      env: ${SOURCE_NAMESPACE}
EOF

echo "Applying the following EgressIP object"
cat ${file}
oc apply -f ${file}

################################################################
# Dial test
################################################################

source_ingress_route="${SOURCE_NAMESPACE}.${ingress_domain}"
target_ip=$(oc get pods -n ${TARGET_NAMESPACE} -l app=${TARGET_NAMESPACE}-deployment -o jsonpath='{.items[0].status.podIP}')

request="http://${source_ingress_route}/dial?host=${target_ip}&port=${TARGET_PORT}&request=/clientip"

for i in {1..10}; do
  echo "${i}: Sending a request to ${request}"
  curl ${request} 2>/dev/null | jq -r '.responses[0]'
done

