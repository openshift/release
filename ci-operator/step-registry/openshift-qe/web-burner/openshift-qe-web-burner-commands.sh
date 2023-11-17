#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x
cat /etc/os-release
oc config view
oc projects
python --version
pushd /tmp
python -m virtualenv ./venv_qe
source ./venv_qe/bin/activate

ES_PASSWORD=$(cat "/secret/password")
ES_USERNAME=$(cat "/secret/username")

# Kube-burner
curl  https://github.com/cloud-bulldozer/kube-burner/releases/download/v${KUBE_BURNER_RELEASE}/kube-burner-V${KUBE_BURNER_RELEASE}-Linux-x86_64.tar.gz -Lo kube-burner.tar.gz
sudo tar -xvzf kube-burner.tar.gz -C /usr/local/bin/
kube-burner version

# Prep
kubectl label $(oc get node --no-headers -l node-role.kubernetes.io/worker= -o name | head -n1) node-role.kubernetes.io/worker-test="" --overwrite=true
kubectl create secret generic kubeconfig --from-file=config=$KUBECONFIG --dry-run=client --output=yaml > objectTemplates/secret_kubeconfig.yml
kubectl get node -o wide

# LB pods
kube-burner init -c workload/cfg_icni2_serving_resource_init.yml --uuid 1234 --timeout 10m
kubectl get po -n serving-ns-0 -o wide
kubectl get po -n served-ns-0 -o wide

# App pods
kube-burner init -c workload/cfg_icni2_node_density2.yml --uuid 1235
kubectl get po -n served-ns-0 -o wide | head
echo "Number of serving running pods (expect 4):"
SERVING_PODS=$(kubectl get po -A | grep serving | grep Running | wc -l)
echo $SERVING_PODS
echo "Number of served running pods (expect 61):"
SERVED_PODS=$(kubectl get po -A | grep served | grep Running | wc -l)
echo $SERVED_PODS
echo "Number of serving deployments (expect 4):"
SERVING_DEPLOYS=$(kubectl get deploy -A | grep serving | wc -l)
echo $SERVING_DEPLOYS
echo "Number of served deployments (expect 1):"
SERVED_DEPLOYS=$(kubectl get deploy -A | grep served | wc -l)
echo $SERVED_DEPLOYS
echo "Number of served services (expect 1):"
SERVED_SVCS=$(kubectl get service -A | grep served | wc -l)
echo $SERVED_SVCS
if [ $SERVING_PODS != 4 ] || [ $SERVED_PODS != 61 ] || [ $SERVING_DEPLOYS != 4 ] || [ $SERVED_DEPLOYS != 1 ] || [ $SERVED_SVCS != 1 ]  ; then
   echo "Incorrect number of objects"
   exit 1
fi
