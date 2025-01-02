#!/bin/bash
set -x
set -o errexit
set -o nounset
set -o pipefail

# Get the current OpenShift version
currentVersion=$(oc version -o yaml | grep openshiftVersion | grep -o '[0-9]*[.][0-9]*' | head -1)

# Get the current network plugin
currentPlugin=$(oc get network.config.openshift.io cluster -o jsonpath='{.status.networkType}')

# Check if the current version and plugin match the expected values
if [[ ${currentVersion} != "4.16" && ${currentVersion} != "4.15" || ${currentPlugin} != "OpenShiftSDN" ]]; then
  echo "Exiting script because the version or plugin is incorrect."
  exit
fi

echo "Version and plugin are correct. Continuing script."

# Wait for ClusterOperators to reach the desired state
co_timeout=${OVN_SDN_MIGRATION_TIMEOUT:-2400s}
timeout "$co_timeout" bash <<EOT
until
  oc wait co --all --for='condition=Available=True' --timeout=10s &&
  oc wait co --all --for='condition=Progressing=False' --timeout=10s &&
  oc wait co --all --for='condition=Degraded=False' --timeout=10s;
do
  sleep 10
  echo "Some ClusterOperators are not in the desired state (Degraded=False, Progressing=False, Available=True)";
done
EOT

oc create namespace z4 && oc label namespace z4 team=qe pod-security.kubernetes.io/audit=privileged pod-security.kubernetes.io/enforce=privileged pod-security.kubernetes.io/warn=privileged security.openshift.io/scc.podSecurityLabelSync=false --overwrite
oc create namespace z3 && oc label namespace z3 pod-security.kubernetes.io/audit=privileged pod-security.kubernetes.io/enforce=privileged pod-security.kubernetes.io/warn=privileged security.openshift.io/scc.podSecurityLabelSync=false --overwrite

for namespace in z3 z4
do
echo 'apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: hello
  namespace: "'$namespace'"
  labels:
    name: test
spec:
  selector:
    matchLabels:
      name: test
  updateStrategy:
    type: RollingUpdate
  template:
    metadata:
      labels:
        name: test
    spec:
      nodeSelector:
        kubernetes.io/arch: amd64
      tolerations:
      - operator: Exists
      containers:
      - name: hello-pod
        image: quay.io/openshifttest/nginx-alpine@sha256:04f316442d48ba60e3ea0b5a67eb89b0b667abf1c198a3d0056ca748736336a0' | oc create -f  -

done	
####Create mco 
nodeNum=$(oc get node --no-headers | wc -l)
cat <<EOF1 | oc create -f -
apiVersion: v1
kind: List
items:
- apiVersion: v1
  kind: Namespace
  metadata:
    labels:
      kubernetes.io/metadata.name: pause-mco-temporary
    name: pause-mco-temporary
  spec: {}
  status: {}
- apiVersion: rbac.authorization.k8s.io/v1
  kind: ClusterRoleBinding
  metadata:
    name: pause-mco-temporary-hostnetwork
  roleRef:
    apiGroup: rbac.authorization.k8s.io
    kind: ClusterRole
    name: system:openshift:scc:hostnetwork
  subjects:
    - kind: ServiceAccount
      name: default
      namespace: pause-mco-temporary
- apiVersion: apps/v1
  kind: Deployment
  metadata:
    name: pause-mco
    namespace: pause-mco-temporary
    labels:
      k8s-app: pause-mco
  spec:
    replicas: ${nodeNum}
    selector:
      matchLabels:
        name: pause-mco
    template:
      metadata:
        labels:
          name: pause-mco
      spec:
        hostNetwork: true
        tolerations:
          - operator: Exists
        containers:
          - name: pause-mco
            command:
              - sleep
            args:
              - infinity
            image: registry.redhat.io/rhel9/support-tools:latest
        affinity:
          podAntiAffinity:
            requiredDuringSchedulingIgnoredDuringExecution:
              - labelSelector:
                  matchLabels:
                    name: pause-mco
                topologyKey: kubernetes.io/hostname
EOF1

timeout 60s bash <<EOT
until
  oc wait pod --for='condition=Ready=True' -n z3 --all
  oc wait pod --for='condition=Ready=True' -n z4 --all
  oc wait pod --for='condition=Ready=True' -n pause-mco-temporary --all
do
  sleep 5
  echo " z3/z4/pause-mco pods not ready"
done
EOT

###create networkpolicy to make pods from z4 can be accessed pods in z3
cat <<EOF | oc create -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
  namespace: z3
spec:
  podSelector: {}
  policyTypes:
  - Ingress
---
kind: NetworkPolicy
apiVersion: networking.k8s.io/v1
metadata:
  name: allow-all-ingress
  namespace: z3
spec:
  ingress:
    - from:
      - namespaceSelector:
          matchLabels:
            team: qe
        podSelector:
          matchLabels:
            name: test
  policyTypes:
    - Ingress
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-from-openshift-ingress
  namespace: z3
spec:
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          policy-group.network.openshift.io/ingress: ""
  podSelector: {}
  policyTypes:
  - Ingress
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-from-hostnetwork
  namespace: z3
spec:
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          policy-group.network.openshift.io/host-network: ""
  podSelector: {}
  policyTypes:
  - Ingress
EOF

# Patch new setting for internalJoinSubnet and internalTransitSwitchSubnet
oc patch network.operator.openshift.io cluster --type='merge'  -p='{"spec":{"defaultNetwork":{"ovnKubernetesConfig":{"ipv4":{"internalJoinSubnet": "100.65.0.0/16"}}}}}' 
oc patch network.operator.openshift.io cluster --type='merge'  -p='{"spec":{"defaultNetwork":{"ovnKubernetesConfig":{"ipv4":{"internalTransitSwitchSubnet": "100.85.0.0/16"}}}}}' 

# Patch the network configuration for live migration
oc patch Network.config.openshift.io cluster --type='merge' --patch '{"metadata":{"annotations":{"network.openshift.io/network-type-migration":""}},"spec":{"networkType":"OVNKubernetes"}}'


timeout 60m bash <<EOT
until
  oc describe pod -n z3 | grep "name.*ovn-kubernetes"
do
  sleep 30
  echo "waiting one node pods begins to use ovn-k cni"
done
EOT

#####now stop migration to test the connection between sdn cni and ovn-k cni in different node
####pause_migration
cat <<EOF | oc create -f -
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  creationTimestamp: null
  name: pause-mco-pdb
  namespace: pause-mco-temporary
spec:
  maxUnavailable: 0
  selector:
      matchLabels:
          name: pause-mco
status: {}
EOF

sleep 180

timeout 300s bash <<EOF
until
  oc wait node --for='condition=Ready=True' --all
do
  sleep 5
  echo "node is not ready"
done
EOF

oc delete pod -n z4 --all
oc delete pod -n z3 --all

timeout 160s bash <<EOT
until
  oc wait pod --for='condition=Ready=True' -n z3 --all
  oc wait pod --for='condition=Ready=True' -n z4 --all
do
  sleep 5
  echo "pods not ready"
done
EOT

pod_name_z4=$(oc get pods -n z4 -o jsonpath='{.items[*].metadata.name}')
pod_ip_z3=$(oc get pods -n z3 -o jsonpath='{.items[*].status.podIP}')

connection_pod2pod=0
for pod_i in $pod_name_z4
do
	echo $pod_i;
	for p_ip in $pod_ip_z3
	do
		echo oc exec -n z4 $pod_i -- curl --connect-timeout 5 network-check-target.openshift-network-diagnostics.svc 2>/dev/null && oc exec -n z4 $pod_i -- curl --connect-timeout 5 ${p_ip}:8080 https://${p_ip}:8443 -k 2>/dev/null && oc exec -n z4 $pod_i -- curl --connect-timeout 5 kubernetes.default.svc:443 -k 2>/dev/null
		oc exec -n z4 $pod_i -- curl --connect-timeout 5 network-check-target.openshift-network-diagnostics.svc 2>/dev/null && echo && oc exec -n z4 $pod_i -- curl --connect-timeout 5 ${p_ip}:8080 https://${p_ip}:8443 -k 2>/dev/null && oc exec -n z4 $pod_i -- curl --connect-timeout 5 kubernetes.default.svc:443 -k 2>/dev/null 
		if [ $? != 0 ]; then
			echo "########################################"
			echo oc exec -n z4 $pod_i -- curl --connect-timeout 5 network-check-target.openshift-network-diagnostics.svc 2>/dev/null && oc exec -n z4 $pod_i -- curl --connect-timeout 5${p_ip}:8080 https://${p_ip}:8443 -k 2>/dev/null && oc exec -n z4 $pod_i -- curl --connect-timeout 5 kubernetes.default.svc:443 -k 2>/dev/null
			echo "########################################"
			echo oc describe pod $pod_i -n z4
			oc describe pod $pod_i -n z4
                        podname_z3=$(oc get pod -n z3 -o wide --no-headers | grep ${p_ip} | cut -f1 -d" ")
			echo "########################################"
			echo oc describe pod $podname_z3 -n z3
			oc describe pod $podname_z3 -n z3
			connection_pod2pod=1
		fi
	done
done

connection_hostnetwork2pod=0
pod_name_multus=$(oc get pods -n openshift-multus -l app=multus -o jsonpath='{.items[*].metadata.name}')
pod_ip_z3=$(oc get pods -n z3 -o jsonpath='{.items[*].status.podIP}')

for pod_i in $pod_name_multus
do
        echo $pod_i;
        for p_ip in $pod_ip_z3
        do
		echo oc exec -n openshift-multus $pod_i -- curl --connect-timeout 3 ${p_ip}:8080 https://${p_ip}:8443 -k 2>/dev/null
                oc exec -n openshift-multus $pod_i -- curl --connect-timeout 3 ${p_ip}:8080 https://${p_ip}:8443 -k 2>/dev/null
                if [ $? != 0 ]; then
                        echo "########################################"
                        echo oc exec -n openshift-multus $pod_i -- curl --connect-timeout 3 ${p_ip}:8080 https://${p_ip}:8443 -k 2>/dev/null
                        echo "########################################"
                        echo oc describe pod $pod_i -n openshift-multus
                        oc describe pod $pod_i -n openshift-multus
                        podname_z3=$(oc get pod -n z3 -o wide --no-headers | grep ${p_ip} | cut -f1 -d" ")
                        echo "########################################"
                        echo oc describe pod $podname_z3 -n z3
                        oc describe pod $podname_z3 -n z3
			connection_hostnetwork2pod=1
                fi
        done
done

if [[ $connection_hostnetwork2pod == 0 && $connection_pod2pod == 0 ]]; then
	###unset pause migration,continue migration
	echo "all connection testing pass with different cni"
	oc delete PodDisruptionBudget pause-mco-pdb -n pause-mco-temporary
else
	#exit for debugging
	echo "connection_hostnetwork2pod:$connection_hostnetwork2pod"
	echo "connection_pod2pod:$connection_pod2pod"
	echo " pod2pod or hostnetwork2pod testing failed, exit"
	exit 2
fi
# Wait for the live migration to fully complete
co_timeout=${OVN_SDN_MIGRATION_TIMEOUT:-3600s}
timeout "$co_timeout" bash <<EOT
until 
  oc get network -o yaml | grep NetworkTypeMigrationCompleted > /dev/null && \
  for NODE in \$(oc get nodes -o custom-columns=NAME:.metadata.name --no-headers); do oc get node \$NODE -o yaml | grep "k8s.ovn.org/node-transit-switch-port-ifaddr:" | grep "100.85";  done > /dev/null && \
  for NODE in \$(oc get nodes -o custom-columns=NAME:.metadata.name --no-headers); do oc get node \$NODE -o yaml | grep "k8s.ovn.org/node-gateway-router-lrp-ifaddr:" | grep "100.65";  done > /dev/null && \
  oc get network.config/cluster -o jsonpath='{.status.networkType}' | grep OVNKubernetes > /dev/null;
do
  echo "Live migration is still in progress"
  sleep 30
done
EOT
echo "The Migration is completed"

# Check all ClusterOperators back to normal after live migration
co_timeout=${OVN_SDN_MIGRATION_TIMEOUT:-3000s}
timeout "$co_timeout" bash <<EOT
until
  oc wait co --all --for='condition=Available=True' --timeout=10s && \
  oc wait co --all --for='condition=Progressing=False' --timeout=10s && \
  oc wait co --all --for='condition=Degraded=False' --timeout=10s; 
do
  sleep 10 && echo "Some ClusterOperators are not in the desired state (Degraded=False, Progressing=False, Available=True)";
done
EOT
echo "All ClusterOperators are in the desired state"

# Output the status of ClusterOperators
oc get co
