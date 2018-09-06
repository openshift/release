# Azure project

Azure project is a flavor of OpenShift dedicated hosted, on Microsoft Azure. This repository contains code for building release artifacts, testing, and life-cycle.
Main code repository is located in [Openshift Azure](https://github.com/openshift/openshift-azure/) project

# Test CI-operator jobs 

CI-Operator jobs are being triggered using [prow](https://github.com/kubernetes/test-infra/tree/master/prow)
Prow configuration is located in this repository `ci-operator/jobs/openshift/openshift-azure/*.yaml`

To run CI-Operator job manually you need to have to have [CI-Operator](https://github.com/openshift/ci-operator) installed in your path.
Modify secret location in file `cluster-launch-e2e-azure.yaml` as below. This is because `ci-operator` set secret based on path where files are located and they are different in local development and CI server.
``` - name: cluster-secrets-azure
      secret:
         secretName: azure
```

Populate secret file in `cluster/test-deploy/azure/secret` using `cluster/test-deploy/azure/secret_example` as template.
If you are running this job not in CI cluster development namespace, but on other OpenShift cluster you will need to pre-populate base images in `azure` namespaces.

Run job:
```
ci-operator --config ci-operator/config/openshift/openshift-azure/master.yaml --namespace=namespace-name --git-ref=openshift/openshift-azure@master --template ci-operator/templates/cluster-launch-e2e-azure.yaml --secret-dir $(pwd)/cluster/test-deploy/azure/
```

# Secret rotation

OSA jobs are using `Web API App` credentials on Azure to run jobs. If for some reason you need to rotate secret, follow this process:

1. Go to `Azure Active Directory` -> `App Registrations` -> `ci-operator-jobs` -> `Settings` -> `Keys`
2. Delete old key, and create new one.
3. Create secret example file:

```
export AZURE_CLIENT_ID=<web app id>
export AZURE_CLIENT_SECRET=<new key>
export AZURE_TENANT_ID=<tenant id>
export AZURE_SUBSCRIPTION_ID=<subscription id>
```

4. Create a secret

```
oc create secret generic cluster-secrets-azure --from-file=cluster/test-deploy/azure/secret -o yaml --dry-run | oc apply -n ci -f -	
```

5. (Optional, if you dont have access to CI namespace)

```
oc apply secret generic cluster-secrets-azure-temp --from-file=cluster/test-deploy/azure/secret -o yaml --dry-run | oc apply -n azure -f -
```

and ask somebody, who has access to execute:

```
oc get secret cluster-secrets-azure-temp --export -n azure -o yaml | sed 's/cluster-secrets-azure-temp/cluster-secrets-azure/g' | oc apply -f - -n ci
```

6. Do the same for azure secret. It has slightly different format:

```
source ./cluster/test-deploy/azure/secret
oc create secret generic cluster-secrets-azure --from-literal=azure_client_id=${AZURE_CLIENT_ID} --from-literal=azure_client_secret=${AZURE_CLIENT_SECRET} --from-literal=azure_tenant_id=${AZURE_TENANT_ID} --from-literal=azure_subscription_id=${AZURE_SUBSCRIPTION_ID} -o yaml --dry-run | oc apply -n azure -f -
```
