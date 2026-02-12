# Deploy Istio Control Plane using Sail Operator Step
This step deploys the Istio control plane using the Sail Operator in an OpenShift cluster. It ensures that the Sail Operator is installed and then deploys the Istio control plane according to the specified configuration.

## Required Parameters
- `KUBECONFIG`: Path to the kubeconfig file for the target OpenShift cluster.
- `ISTIO_CONTROL_PLANE_MODE`: The mode of the Istio control plane to deploy, only allowed value is `ambient` and `sidecar`. The default is `sidecar`.
- `SAIL_OPERATOR_CHANNEL`: The channel of the Sail Operator to use in the subscription. Default is `1.28-nightly` to ensure compatibility with the latest Istio versions from master branch in the Sail Operator.
- `SKIP_CREATE_TEST_RESOURCES`: Needs to be set to `'true'`, skips the creation of test resources during the deployment. This means that the cluster will be created but Masitra namespace and pods will not be created. This Maistra pods are used for OSSM tests specifically.

## Step Overview
1. **Deploy Sail Operator**: The step first applies the Sail Operator subscription to install the operator in the `openshift-operators` namespace. It waits for the Sail Operator deployment to become available.
2. **Deploy Istio Control Plane**: After the Sail Operator is confirmed to be running, the step applies the Istio control plane custom resource definition (CRD) to deploy the control plane in the `istio-system` namespace. It waits for the `istiod` deployment and the Istio CNI DaemonSet to become available.
3. **Ambient Mode Verification**: If the `ISTIO_CONTROL_PLANE_MODE` is set to `ambient`, the step also verifies the deployment of the Ztunnel DaemonSet.
4. **Debug Information**: Finally, the step lists all pods in all namespaces for debugging purposes.

## Usage
To use this step in your CI/CD pipeline, include it in your job configuration and provide the required parameters. Make sure to adjust the `SAIL_OPERATOR_CHANNEL` if you need a specific version of the Sail Operator, the recommended is to use the default channel for latest features and fixes.

## Example
```yaml
- as: performance-sail-ocp
  steps:
    cluster_profile: ossm-aws
    env:
      BASE_DOMAIN: servicemesh.devcluster.openshift.com
      ISTIO_CONTROL_PLANE_MODE: ambient
      SKIP_CREATE_TEST_RESOURCES: 'true'
    test:
    - ref: servicemesh-sail-operator-deploy-controlplane
    workflow: servicemesh-istio-e2e-hypershift
```