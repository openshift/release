        #Gather tag and image for deployment
        IN=$ODH_NOTEBOOK_CONTROLLER_IMAGE
        arrIN=(${IN//:/ })
        export IMG=${arrIN[1]}  
        export TAG=${arrIN[2]}

        # Setup and test odh-nbc
        pushd components/odh-notebook-controller
        oc new-project odh-notebook-controller-system
        make deploy -e K8S_NAMESPACE=odh-notebook-controller-system

        mkdir -p ~/.kube
        cp /tmp/kubeconfig ~/.kube/config 2> /dev/null || cp /var/run/secrets/ci.openshift.io/multi-stage/kubeconfig ~/.kube/config
        chmod 644 ~/.kube/config
        export KUBECONFIG=~/.kube/config

        make e2e-test -e K8S_NAMESPACE=odh-notebook-controller-system

        # Clean up
        make undeploy -e K8S_NAMESPACE=odh-notebook-controller-system
        oc delete project odh-notebook-controller-system
