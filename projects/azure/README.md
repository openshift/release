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
ci-operator --config ci-operator/config/openshift/openshift-azure/master.json --namespace=namespace-name --git-ref=openshift/openshift-azure@master --template ci-operator/templates/cluster-launch-e2e-azure.yaml --secret-dir $(pwd)/cluster/test-deploy/azure/
```
