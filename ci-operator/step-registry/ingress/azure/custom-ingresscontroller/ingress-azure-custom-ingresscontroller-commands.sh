#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export KUBECONFIG=${SHARED_DIR}/kubeconfig

CLUSTER_NAME="${NAMESPACE}-${UNIQUE_HASH}"

AZURE_REGION="${LEASED_RESOURCE}"
echo "Azure region: ${AZURE_REGION}"

AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
AZURE_AUTH_CLIENT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientId)"
AZURE_AUTH_CLIENT_SECRET="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientSecret)"
AZURE_AUTH_TENANT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .tenantId)"

# log in with az
az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none

AZURE_BASE_DOMAIN="$(oc get -o jsonpath='{.spec.baseDomain}' dns.config cluster)"
Infra_ID=$(oc get -o jsonpath='{.status.infrastructureName}{"\n"}' infrastructure cluster)
canary_host=$(oc get route canary -n openshift-ingress-canary -o jsonpath='{.spec.host}')
Image_ID=$(oc get machines -n openshift-machine-api -o jsonpath='{.items[0].spec.providerSpec.value.image.resourceID}')

echo "$(date -u --rfc-3339=seconds) Create a new subnet for the infrastructure nodes"
az network vnet subnet create -g ${CLUSTER_NAME}-rg --vnet-name ${CLUSTER_NAME}-vnet -n ${CLUSTER_NAME}-ingress-subnet --address-prefixes 10.0.64.0/24 --network-security-group ${CLUSTER_NAME}-nsg

echo "Create the infra MCP"
oc create -f - <<EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfigPool
metadata:
  name: infra
spec:
  machineConfigSelector:
    matchExpressions:
      - {key: machineconfiguration.openshift.io/role, operator: In, values: [worker,infra]}
  nodeSelector:
    matchLabels:
      ingress: "true"
EOF

echo "Create the infra machineset with label ingress: 'true'"
oc create -f - <<EOF
apiVersion: machine.openshift.io/v1beta1
kind: MachineSet
metadata:
  labels:
    machine.openshift.io/cluster-api-cluster: ${Infra_ID}
    machine.openshift.io/cluster-api-machine-role: infra
    machine.openshift.io/cluster-api-machine-type: worker
  name: ${Infra_ID}-ingress
  namespace: openshift-machine-api
spec:
  replicas: 3
  selector:
    matchLabels:
      machine.openshift.io/cluster-api-cluster: ${Infra_ID}
      machine.openshift.io/cluster-api-machineset: ${Infra_ID}-ingress
  template:
    metadata:
      labels:
        machine.openshift.io/cluster-api-cluster: ${Infra_ID}
        machine.openshift.io/cluster-api-machine-role: infra
        machine.openshift.io/cluster-api-machine-type: worker
        machine.openshift.io/cluster-api-machineset: ${Infra_ID}-ingress
    spec:
      metadata:
        labels:
          ingress: "true"
          node-role.kubernetes.io/infra: ""
      providerSpec:
        value:
          acceleratedNetworking: true
          apiVersion: machine.openshift.io/v1beta1
          credentialsSecret:
            name: azure-cloud-credentials
            namespace: openshift-machine-api
          image:
            offer: ""
            publisher: ""
            resourceID: ${Image_ID}
            sku: ""
            version: ""
          kind: AzureMachineProviderSpec
          location: ${AZURE_REGION}
          managedIdentity: ${Infra_ID}-identity
          metadata: {}
          networkResourceGroup: ${CLUSTER_NAME}-rg
          osDisk:
            diskSizeGB: 128
            managedDisk:
              storageAccountType: Premium_LRS
            osType: Linux
          publicIP: false
          publicLoadBalancer: ${Infra_ID}
          resourceGroup: ${Infra_ID}-rg
          subnet: ${CLUSTER_NAME}-ingress-subnet
          userDataSecret:
            name: worker-user-data
          vmSize: ${COMPUTE_NODE_TYPE}
          vnet: ${CLUSTER_NAME}-vnet
          zone: ""
EOF

function wait_for_mcp() {
    local try=0 retries=60

    ### $6 $7 $8 $9: MACHINECOUNT READYMACHINECOUNT UPDATEDMACHINECOUNT DEGRADEDMACHINECOUNT
    while [ X"$(oc get mcp infra --no-headers |awk '{print $6 $7 $8 $9}')" != X"3330" ] && [ $try -lt $retries ]; do
        echo "MCP infra is still updating..."
        sleep 30
        try=$(expr $try + 1)
    done
    if [ X"$try" == X"$retries" ]; then
        echo "MCP is not ready in the end, maybe something wrong with the new nodes"
	oc get mcp infra -o yaml
        return 1
    fi
    return 0
}

wait_for_mcp || exit 2

echo "Create taint to exlcude pods from running on the infra workers"
oc adm taint nodes -l ingress=true infra=reserved:NoSchedule infra=reserved:NoExecute

echo "Update the ingress node ROLE to be infra only, remove worker role if present"
oc label node node-role.kubernetes.io/worker- node-role.kubernetes.io/infra= -l ingress=true --overwrite

echo "Create the testing custom ingress controller "
oc create -f - <<EOF
apiVersion: operator.openshift.io/v1
kind: IngressController
metadata:
  name: apps1
  namespace: openshift-ingress-operator
spec:
  domain: apps1.${CLUSTER_NAME}.${AZURE_BASE_DOMAIN}
  nodePlacement:
    nodeSelector:
      matchLabels:
        ingress: "true"
    tolerations:
    - effect: NoSchedule
      key: infra
      value: reserved
    - effect: NoExecute
      key: infra
      value: reserved
EOF

echo "Wait for the custom ingresscontroller to be ready"

oc wait co ingress --for='condition=PROGRESSING=True' --timeout=30s

# Check cluster operator ingress back to normal
timeout 300s bash <<EOT
until
  oc wait co ingress --for='condition=Available=True' --timeout=10s && \
  oc wait co ingress --for='condition=Progressing=False' --timeout=10s && \
  oc wait co ingress --for='condition=Degraded=False' --timeout=10s;
do
  sleep 10 && echo "Cluster Operator ingress Degraded=True,Progressing=True,or Available=False";
done
EOT

echo "Get basic var for post actions"
custom_public_ip=$(oc get svc router-apps1 -n openshift-ingress --no-headers  | awk '{print $4}')
custom_lb_name=$(az network public-ip list -g ${Infra_ID}-rg -o table |grep ${custom_public_ip} |awk '{print $1}' | awk -F "-" '{print $NF}')
health_check_port=$(oc get svc router-apps1  -n openshift-ingress -o json | jq -r .spec.healthCheckNodePort)

if [ -z "$custom_public_ip" ] || [ -z "$custom_lb_name" ] || [ -z "$health_check_port" ]
then
    echo "Basic var is empty, please have a check with your ingress controller pod" && exit 1
fi

echo "List the Frontend Public IP addresses"
az network lb frontend-ip list -g ${Infra_ID}-rg --lb-name ${Infra_ID} |jq -r .[].name || exit 4

echo "Start to removing the custom ingress controller resources from default LB"

echo "Deleting LB rules"
for rule in `az network lb rule list -g ${Infra_ID}-rg --lb-name ${Infra_ID} | jq -r .[].name |grep ${custom_lb_name}`
do
    az network lb rule delete -g ${Infra_ID}-rg --lb-name ${Infra_ID} -n ${rule} || exit 4
done

echo "Deleting health probe"
for probe in `az network lb probe list -g ${Infra_ID}-rg --lb-name ${Infra_ID} | jq -r .[].name  |grep ${custom_lb_name}`
do
    az network lb probe delete -g ${Infra_ID}-rg --lb-name ${Infra_ID} -n ${probe} || exit 4
done

echo "Deleting frontend ip"
az network lb frontend-ip delete -g ${Infra_ID}-rg --lb-name ${Infra_ID} -n ${custom_lb_name} || exit 4

echo "Deleting backend pool"
ingress_node_list=$(oc get node -l ingress=true --no-headers |awk '{print $1}')

for node in ${ingress_node_list}
do
    az network nic ip-config address-pool remove --address-pool ${Infra_ID} --nic-name ${node}-nic -n pipConfig -g ${Infra_ID}-rg --lb-name ${Infra_ID} || exit 4
done


echo "start to create the custom LB"
az network lb create --resource-group ${Infra_ID}-rg --name ${Infra_ID}-ingress --sku Standard --public-ip-address ${Infra_ID}-ingress-lb-pip --frontend-ip-name ingress-public-lb-ip-v4 --backend-pool-name ${Infra_ID}-ingress || exit 4

echo "Create the frontend IP"
az network lb frontend-ip create --lb-name ${Infra_ID}-ingress --name apps1-ingress  --public-ip-address ${Infra_ID}-${custom_lb_name} -g ${Infra_ID}-rg || exit 4

echo "Create the probe"
for port in 80 443
do
    az network lb probe create -g ${Infra_ID}-rg --lb-name ${Infra_ID}-ingress -n apps1-tcp-${port} --protocol http --port ${health_check_port} --path /healthz --interval 5 --threshold 2 || exit 4
done

echo "Create the rule"
for port in 80 443
do
    az network lb rule create -g ${Infra_ID}-rg --lb-name ${Infra_ID}-ingress --name apps1-tcp-${port} --protocol tcp --frontend-port ${port} --backend-port ${port} --frontend-ip-name apps1-ingress --backend-pool-name ${Infra_ID}-ingress --probe-name apps1-tcp-${port} --disable-outbound-snat false --idle-timeout 4 --enable-tcp-reset true --floating-ip true || exit 4
done

echo "Add instance to the pool"
for node in ${ingress_node_list}
do
    az network nic ip-config address-pool add --address-pool ${Infra_ID}-ingress --nic-name ${node}-nic -g ${Infra_ID}-rg -n pipConfig --lb-name ${Infra_ID}-ingress || exit 4
done

echo "Check the route reachability via the custom ingresscontroller LB"
curl -kI --resolve ${canary_host}:443:${custom_public_ip} https://${canary_host}
