#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

max_cpus=8

# Check if this is an AWS instance
aws_pattern="[a-z]{1}[0-9]{1}[a-z]{1}\.(metal)?-*([0-9]+)"
if [[ ${SINGLE_NODE_AWS_INSTANCE_TYPE-"not_provided"} =~ $aws_pattern ]]
then

  if [[ "${BASH_REMATCH[1]}" != "metal" ]]; then
    echo "The realtime performance profile should only be applied to AWS metal instances. $SINGLE_NODE_AWS_INSTANCE_TYPE is not a metal instance"
    exit 1
  fi

  max_cpus=$((BASH_REMATCH[2] * 4)) # Calculate the cores from the instance type (assumed XL)
else
  echo "${SINGLE_NODE_AWS_INSTANCE_TYPE} is not a supported instance type"
  exit 1
fi

# Make sure we are not designating all the cores to reserved
if [[ $RESERVED_CPU_COUNT -ge $max_cpus ]]; then
  echo "ERROR: not enough cores available to specify isolated CPUs. Reserved CPUs: ${RESERVED_CPU_COUNT}, Total CPUs: ${max_cpus}"
  exit 1
fi

echo "Creating new performance profile manifest for the cluster"
oc create -f - <<EOF
apiVersion: performance.openshift.io/v2
kind: PerformanceProfile
metadata:
  name: openshift-single-node-cpu-rt-master
spec:
  realTimeKernel:
    enabled: true
  cpu:
    reserved: 0-$((RESERVED_CPU_COUNT - 1))
    isolated: $RESERVED_CPU_COUNT-$((max_cpus - 1))
  machineConfigPoolSelector:
    pools.operator.machineconfiguration.openshift.io/master: ""
  nodeSelector:
    node-role.kubernetes.io/master: ""
  workloadHints:
    highPowerConsumption: true
    realTime: true
EOF

# Wait for the node restart to trigger, this can take a few minutes
SECONDS=0
echo "Waiting up to 10 minutes for the node to trigger a restart"
until ! oc get clusterversion &> /dev/null
do
  if [ $SECONDS -ge 600 ]; then
    echo "ERROR: timed out waiting for the node to begin rebooting"
    exit 1
  fi

  echo -n .
  sleep 10
done

echo

# Wait for the api server to come back up
SECONDS=0
echo "Waiting up to 20 minutes for the node to finish rebooting"
until oc get clusterversion &> /dev/null
do
  if [ $SECONDS -ge 1200 ]; then
    echo "ERROR: timed out waiting for the node to reboot"
    exit 1
  fi

  echo -n .
  sleep 10
done

echo

# Wait for and validate the new kernel version to be reflected
echo "Validating the updated kernel version"
node_name=$(oc get nodes -o jsonpath='{.items[*].metadata.name}')
kernel_info=$(oc debug --to-namespace='default' --quiet node/${node_name} -- uname -r)

if [[ $kernel_info != *"+rt" ]]; then
  echo "ERROR: the kernel version ${kernel_info} on node ${node_name} does not have the real-time modifier '+rt'"
  exit 1
fi

node_info=$(oc get nodes -o jsonpath='{.items[*].status.nodeInfo.kernelVersion}')

if [[ $node_info != "$kernel_info" ]]; then
  echo "ERROR: nodeInfo.kernelVersion is not properly reflecting the realtime kernel update. Observed '${node_info}' but expected '${kernel_info}'"
  exit 1
fi

echo "Successfully activated the realtime kernel '$kernel_info'"
