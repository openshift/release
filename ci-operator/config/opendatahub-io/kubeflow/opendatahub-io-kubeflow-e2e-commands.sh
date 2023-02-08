#Gather tag and image for deployment
IN=$ODH_NOTEBOOK_CONTROLLER_IMAGE
arrIN=(${IN//:/ })
export IMG=${arrIN[0]}  
export TAG=${arrIN[1]}

# Setup and test odh-nbc
pushd components/odh-notebook-controller
oc new-project odh-notebook-controller-system
make deploy -e K8S_NAMESPACE=odh-notebook-controller-system

# Copy the current KUBECONFIG to a writable location so we modify the current context for the test run
cp $KUBECONFIG /tmp/kubeconfig
chmod 644 /tmp/kubeconfig
export KUBECONFIG=/tmp/kubeconfig

make e2e-test -e K8S_NAMESPACE=odh-notebook-controller-system

# Clean up
make undeploy -e K8S_NAMESPACE=odh-notebook-controller-system
oc delete project odh-notebook-controller-system
