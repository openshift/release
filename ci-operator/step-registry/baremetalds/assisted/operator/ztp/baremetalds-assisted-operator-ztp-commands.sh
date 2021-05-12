#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds assisted operator ztp command ************"

# Fetch packet basic configuration
# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

# Copy additional dev-script variables, if present
if [[ -e "${SHARED_DIR}/ds-vars.conf" ]]
then
  scp "${SSHOPTS[@]}" "${SHARED_DIR}/ds-vars.conf" "root@${IP}:ds-vars.conf"
fi

# Copy job variables to the packet server
echo "export OPENSHIFT_INSTALL_RELEASE_IMAGE=${OPENSHIFT_INSTALL_RELEASE_IMAGE}" >> /tmp/assisted-vars.conf
echo "export ASSISTED_NAMESPACE=${ASSISTED_NAMESPACE}" >> /tmp/assisted-vars.conf
echo "export ASSISTED_CLUSTER_NAME=${ASSISTED_CLUSTER_NAME}" >> /tmp/assisted-vars.conf
echo "export ASSISTED_CLUSTER_DEPLOYMENT_NAME=${ASSISTED_CLUSTER_DEPLOYMENT_NAME}" >> /tmp/assisted-vars.conf
echo "export ASSISTED_INFRAENV_NAME=${ASSISTED_INFRAENV_NAME}" >> /tmp/assisted-vars.conf
echo "export ASSISTED_PRIVATEKEY_NAME=${ASSISTED_PRIVATEKEY_NAME}" >> /tmp/assisted-vars.conf
echo "export ASSISTED_PULLSECRET_NAME=${ASSISTED_PULLSECRET_NAME}" >> /tmp/assisted-vars.conf
echo "export ASSISTED_PULLSECRET_JSON=${ASSISTED_PULLSECRET_JSON}" >> /tmp/assisted-vars.conf
scp "${SSHOPTS[@]}" "/tmp/assisted-vars.conf" "root@${IP}:assisted-vars.conf"

ssh "${SSHOPTS[@]}" "root@${IP}" bash - <<"EOF" |& sed -e 's/.*auths\{0,1\}".*/*** PULL_SECRET ***/g'

source /root/ds-vars.conf
source /root/assisted-vars.conf

echo "Step configuration:"
env | sort

echo "Generate Assisted Installer CRDs"
cat > assisted-installer-crds-playbook.yaml <<EOPB
- name: Create CRDs for Assisted Installer
  hosts: localhost
  collections:
   - community.general
  gather_facts: no
  vars:
    - assisted_namespace: "{{ lookup('env', 'ASSISTED_NAMESPACE') }}"
    - cluster_name: "{{ lookup('env', 'ASSISTED_CLUSTER_NAME') }}"
    - cluster_image_set_name: "{{ lookup('env', 'DS_OPENSHIFT_VERSION') }}"
    - cluster_release_image: "{{ lookup('env', 'OPENSHIFT_INSTALL_RELEASE_IMAGE') }}"
    - cluster_deployment_name: "{{ lookup('env', 'ASSISTED_CLUSTER_DEPLOYMENT_NAME') }}"
    - infraenv_name: "{{ lookup('env', 'ASSISTED_INFRAENV_NAME') }}"
    - pull_secret_name: "{{ lookup('env', 'ASSISTED_PULLSECRET_NAME') }}"
    - ssh_private_key_name: "{{ lookup('env', 'ASSISTED_PRIVATEKEY_NAME') }}"
    - ssh_public_key: "{{ lookup('file', '/root/.ssh/id_rsa.pub') }}"

  tasks:
  - name: write the cluster image set crd
    template:
      src: "clusterImageSet.j2"
      dest: "clusterImageSet.yaml"

  - name: write the infraEnv crd
    template:
      src: "infraEnv.j2"
      dest: "infraEnv.yaml"

  - name: write the clusterDeployment crd
    template:
      src: "clusterDeployment.j2"
      dest: "clusterDeployment.yaml"
EOPB

cat > clusterImageSet.j2 <<EOCR
apiVersion: hive.openshift.io/v1
kind: ClusterImageSet
metadata:
  name: '{{ cluster_image_set_name }}'
  namespace: {{ assisted_namespace }}
spec:
  releaseImage: '{{ cluster_release_image }}'
EOCR

cat > infraEnv.j2 <<EOCR
apiVersion: agent-install.openshift.io/v1beta1
kind: InfraEnv
metadata:
  name: {{ infraenv_name }}
spec:
  clusterRef:
    name: {{ cluster_name }}
    namespace: {{ assisted_namespace }}
  agentLabelSelector:
    matchLabels:
      bla: aaa
  pullSecretRef:
    name: {{ pull_secret_name }}
  sshAuthorizedKey: '{{ ssh_public_key }}'
EOCR

cat > clusterDeployment.j2 <<EOCR
apiVersion: hive.openshift.io/v1
kind: ClusterDeployment
metadata:
  name: {{ cluster_deployment_name }}
  namespace: {{ assisted_namespace }}
spec:
  baseDomain: redhat.com
  clusterName: {{ cluster_name }}
  platform:
    agentBareMetal:
      apiVIP: ""
      ingressVIP: ""
      agentSelector:
        matchLabels:
          bla: aaa
  provisioning:
    imageSetRef:
      name: '{{ cluster_image_set_name }}'
    sshPrivateKeySecretRef:
      name: {{ ssh_private_key_name }}
    installStrategy:
      agent:
        sshPublicKey: '{{ ssh_public_key }}'
        networking:
          clusterNetwork:
            - cidr: 10.128.0.0/14
              hostPrefix: 23
          serviceNetwork:
            - 172.30.0.0/16
        provisionRequirements:
          controlPlaneAgents: 1
  pullSecretRef:
    name: {{ pull_secret_name }}
EOCR

echo "Running Ansible playbook to create kubernetes configs"
ansible-playbook assisted-installer-crds-playbook.yaml

echo "Assisted Installer pods"
oc get pods -n assisted-installer

echo "Metal3 pods"
oc get pods -A | grep metal3

echo "VM status"
virsh list --all
vm=""
vm=$(virsh list --all | grep "shut off" | awk '{print $2}')
echo "Offline VM for ZTP is $vm"

echo "Creating Assisted Installer Pull Secret"
oc create secret generic ${ASSISTED_PULLSECRET_NAME} --from-file=.dockerconfigjson=${ASSISTED_PULLSECRET_JSON} --type=kubernetes.io/dockerconfigjson -n ${ASSISTED_NAMESPACE}

echo "Creating Assisted Installer Private Key"
oc create secret generic ${ASSISTED_PRIVATEKEY_NAME} --from-file=ssh-privatekey=/root/.ssh/id_rsa --type=kubernetes.io/ssh-auth -n ${ASSISTED_NAMESPACE}

echo "Creating Assisted Installer Cluster Image Set"
oc create -f clusterImageSet.yaml

echo "Creating Assisted Installer SNO ClusterDeployment"
oc create -f clusterDeployment.yaml

echo "Creating Assisted Installer InfraEnv"
oc create -f infraEnv.yaml

echo "Creating new baremetal host using baremetal operator"
oc create -f /root/dev-scripts/ocp/ostest/extra_host_manifests.yaml
oc label -f /root/dev-scripts/ocp/ostest/extra_host_manifests.yaml "infraenvs.agent-install.openshift.io=${ASSISTED_INFRAENV_NAME}"
oc label -f /root/dev-scripts/ocp/ostest/extra_host_manifests.yaml "bla=aaa"

echo "VM status"
virsh list --all
oc get pods -A | grep metal3

echo "List clusterdeploments"
oc get clusterdeployment -n ${ASSISTED_NAMESPACE}
oc get clusterdeployment -n ${ASSISTED_NAMESPACE} -o json | jq '.status.conditions[] | select(.reason | contains("AgentPlatformState"))'

status=""
for (( i=0; i<5; i++ ))
do 
  status=$(virsh list --all | grep $vm | awk '{print $3}')
  if [ "$status" != "running" ]
  then
    echo "$vm is not running ($i retries)"
    sleep 1m
  else
    echo "$vm was started"
    break
  fi
done

if [ "$status" != "running" ]
then
  echo "$vm never started"
  exit 1
else
  echo "$vm was started"
fi

EOF