#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ add-worker manual command ************"

source "${SHARED_DIR}/packet-conf.sh"

ssh "${SSHOPTS[@]}" "root@${IP}" bash - << 'EOF' |& sed -e 's/.*auths\{0,1\}".*/*** PULL_SECRET ***/g'
free -h
SSH_PUB_KEY=$(cat /root/.ssh/id_rsa.pub)
HOSTED_CLUSTER_NS=$(oc get hostedcluster -A -ojsonpath='{.items[0].metadata.namespace}')
HOSTED_CLUSTER_NAME=$(oc get hostedclusters -A -ojsonpath="{.items[0].metadata.name}")
HOSTED_CONTROL_PLANE_NAMESPACE=${HOSTED_CLUSTER_NS}"-"${HOSTED_CLUSTER_NAME}

oc apply -f - <<END
apiVersion: agent-install.openshift.io/v1beta1
kind: InfraEnv
metadata:
  name: ${HOSTED_CLUSTER_NAME}
  namespace: ${HOSTED_CONTROL_PLANE_NAMESPACE}
spec:
  cpuArchitecture: x86_64
  pullSecretRef:
    name: pull-secret
  sshAuthorizedKey: ${SSH_PUB_KEY}
END
oc wait --timeout=10m --for=condition=ImageCreated -n ${HOSTED_CONTROL_PLANE_NAMESPACE} InfraEnv/${HOSTED_CLUSTER_NAME}

ISODownloadURL=$(oc get InfraEnv/${HOSTED_CLUSTER_NAME} -n ${HOSTED_CONTROL_PLANE_NAMESPACE} -ojsonpath='{.status.isoDownloadURL}')
curl -L --fail -o /var/lib/libvirt/images/extraworker.iso --insecure ${ISODownloadURL}
source dev-scripts-additional-config

for ((i = 0; i < $NUM_EXTRA_WORKERS; i++)); do
    virsh dumpxml "ostest_extraworker_$i" > "/tmp/ostest_extraworker_$i.xml"
    sed -i "/<devices>/a \\
     <disk type='file' device='cdrom'>\\
       <driver name='qemu' type='raw'/>\\
       <source file='/var/lib/libvirt/images/extraworker.iso'/>\\
       <target dev='sdb' bus='scsi'/>\\
       <readonly/>\\
     </disk>" "/tmp/ostest_extraworker_$i.xml"
    sed -i "s/<boot dev='network'\/>/<boot dev='hd'\/>/g" "/tmp/ostest_extraworker_$i.xml"
    virsh define "/tmp/ostest_extraworker_$i.xml"
    virsh start "ostest_extraworker_$i"
done

_agentExist=0
set +e
for ((i=1; i<=10; i++)); do
    count=$(oc get agent -n ${HOSTED_CONTROL_PLANE_NAMESPACE} --no-headers --ignore-not-found | wc -l)
    if [ ${count} == ${NUM_EXTRA_WORKERS} ]  ; then
        echo "agent resources already exist"
        _agentExist=1
        break
    fi
    echo "Waiting on agent resources create"
    sleep 60
done
set -e
if [ $_agentExist -eq 0 ]; then
  echo "FATAL: agent cr not Exist"
  exit 1
fi

echo "update agent spec.approved to true"
for item in $(oc get agent -n ${HOSTED_CONTROL_PLANE_NAMESPACE} --no-headers | awk '{print $1}'); do
oc patch agent -n ${HOSTED_CONTROL_PLANE_NAMESPACE} ${item} -p '{"spec":{"approved":true}}' --type merge
done

echo "scale nodepool replicas => $NUM_EXTRA_WORKERS"
oc scale nodepool ${HOSTED_CLUSTER_NAME} -n ${HOSTED_CLUSTER_NS} --replicas ${NUM_EXTRA_WORKERS}
echo "wait agent ready"
oc wait --all=true agent -n ${HOSTED_CONTROL_PLANE_NAMESPACE} --for=jsonpath='{.status.debugInfo.state}'=added-to-existing-cluster --timeout=30m
EOF
