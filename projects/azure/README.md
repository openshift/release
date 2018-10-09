# Azure project

Azure project is a flavor of OpenShift dedicated hosted, on Microsoft Azure. This repository contains code for building release artifacts, testing, and life-cycle.
Main code repository is located in [Openshift Azure](https://github.com/openshift/openshift-azure/) project

# Test CI-operator jobs 

CI-Operator jobs are being triggered using [prow](https://github.com/kubernetes/test-infra/tree/master/prow).
The Prow configuration is located in files within this repository at `ci-operator/jobs/openshift/openshift-azure/*.yaml`

To run a CI-Operator job manually it is recommended to use the [CI-Operator](https://github.com/openshift/ci-operator) container image
```
docker pull registry.svc.ci.openshift.org/ci/ci-operator:latest
```

The templates used to run all of our ci-operator jobs (vm image builds and e2e tests) are located in 

```
ci-operator/templates/openshift/openshift-azure/
```

Obtain the `oc login` command from the OpenShift CI WebConsole and perform a login in your terminal

Note: all further instructions assume you are currently in the root directory of this repository

Create a `secret` file for storing azure-related secrets using `cluster/test-deploy/azure/secret_example` as a template.

```
cp cluster/test-deploy/azure/secret_example cluster/test-deploy/azure/secret
# insert/update credentials in cluster/test-deploy/azure/secret
```

Set the location of the namespace you wish to use for the ci-operator jobs
```
export CI_OPERATOR_NAMESPACE=your-chosen-namespace
```

#### Testing vm image builds

Generate a new ssh keypair making sure to set the name of the keypair file as `ssh-privatekey`

```
ssh-keygen -t rsa -b 4096 -f cluster/test-deploy/azure/ssh-privatekey 
```

Checkout the repository containing the yum client certificates required by openshift-ansible to update the packages on the root VM.
```
git clone git@github.com:openshift/aos-ansible.git ../aos-ansible
```

Create `cluster/test-deploy/azure/certs.yaml` with the following format making sure to replace the `<contents of *>` placeholders
```
yum_client_cert_contents: |
	<contents of ../aos-ansible/playbooks/roles/ops_mirror_bootstrap/files/client-cert.pem>

yum_client_key_contents: |
	<contents of ../aos-ansible/playbooks/roles/ops_mirror_bootstrap/files/client-key.pem>
```

Example: Build a rhel base vm image
```
docker run \
--rm \
-it \
--env DEPLOY_OS=rhel7 \
--volume $HOME/.kube/config:/root/.kube/config \
--volume $(pwd):/release \
registry.svc.ci.openshift.org/ci/ci-operator:latest \
--config /release/ci-operator/config/openshift/openshift-azure/openshift-openshift-azure-master.yaml \
--git-ref=openshift/openshift-azure@master \
--namespace=${CI_OPERATOR_NAMESPACE} \
--template /release/ci-operator/templates/openshift/openshift-azure/build-base-image.yaml \
--secret-dir /release/cluster/test-deploy/azure/ \
--target build-base-image
```

Example: Build a centos base vm image
```
docker run \
--rm \
-it \
--env DEPLOY_OS=centos \
--volume $HOME/.kube/config:/root/.kube/config \
--volume $(pwd):/release \
registry.svc.ci.openshift.org/ci/ci-operator:latest \
--config /release/ci-operator/config/openshift/openshift-azure/openshift-openshift-azure-master.yaml \
--git-ref=openshift/openshift-azure@master \
--namespace=${CI_OPERATOR_NAMESPACE} \
--template /release/ci-operator/templates/openshift/openshift-azure/build-base-image.yaml \
--secret-dir /release/cluster/test-deploy/azure/ \
--target build-base-image
```

Example: Build a rhel node vm image with openshift 3.10
```
docker run \
--rm \
-it \
--env DEPLOY_OS=rhel7 \
--env OPENSHIFT_RELEASE="3.10" \
--volume $HOME/.kube/config:/root/.kube/config \
--volume $(pwd):/release \
registry.svc.ci.openshift.org/ci/ci-operator:latest \
--config /release/ci-operator/config/openshift/openshift-azure/openshift-openshift-azure-master.yaml \
--git-ref=openshift/openshift-azure@master \
--namespace=${CI_OPERATOR_NAMESPACE} \
--template /release/ci-operator/templates/openshift/openshift-azure/build-node-image.yaml \
--secret-dir /release/cluster/test-deploy/azure/ \
--target build-node-image
```

Example: Build a centos node vm image with openshift 3.10
```
docker run \
--rm \
-it \
--env DEPLOY_OS=centos \
--env OPENSHIFT_RELEASE="3.10" \
--volume $HOME/.kube/config:/root/.kube/config \
--volume $(pwd):/release \
registry.svc.ci.openshift.org/ci/ci-operator:latest \
--config /release/ci-operator/config/openshift/openshift-azure/openshift-openshift-azure-master.yaml \
--git-ref=openshift/openshift-azure@master \
--namespace=${CI_OPERATOR_NAMESPACE} \
--template /release/ci-operator/templates/openshift/openshift-azure/build-node-image.yaml \
--secret-dir /release/cluster/test-deploy/azure/ \
--target build-node-image
```

#### Running e2e tests

Example: Run e2e tests
```
docker run \
--rm \
-it \
--volume $HOME/.kube/config:/root/.kube/config \
--volume $(pwd):/release \
registry.svc.ci.openshift.org/ci/ci-operator:latest \
--config ci-operator/config/openshift/openshift-azure/openshift-openshift-azure-master.yaml \
--git-ref=openshift/openshift-azure@master \
--namespace=${CI_OPERATOR_NAMESPACE} \
--template ci-operator/templates/openshift/openshift-azure/cluster-launch-e2e-azure.yaml \
--secret-dir /release/cluster/test-deploy/azure/
```

Example: Run an upgrade and then perform e2e tests
```
docker run \
--rm \
-it \
--volume $HOME/.kube/config:/root/.kube/config \
--volume $(pwd):/release \
registry.svc.ci.openshift.org/ci/ci-operator:latest \
--config ci-operator/config/openshift/openshift-azure/openshift-openshift-azure-master.yaml \
--git-ref=openshift/openshift-azure@master \
--namespace=${CI_OPERATOR_NAMESPACE} \
--template ci-operator/templates/openshift/openshift-azure/cluster-launch-e2e-azure-upgrade.yaml \
--secret-dir /release/cluster/test-deploy/azure/
```

Example: Run origin conformance tests
```
docker run \
--rm \
-it \
--env TEST_COMMAND="TEST_FOCUS=Suite:openshift/conformance/parallel run-tests" \
--volume $HOME/.kube/config:/root/.kube/config \
--volume $(pwd):/release \
registry.svc.ci.openshift.org/ci/ci-operator:latest \
--config ci-operator/config/openshift/openshift-azure/openshift-openshift-azure-master.yaml \
--git-ref=openshift/openshift-azure@master \
--namespace=${CI_OPERATOR_NAMESPACE} \
--template ci-operator/templates/openshift/openshift-azure/cluster-launch-e2e-azure-conformance.yaml \
--secret-dir /release/cluster/test-deploy/azure/
```

#### Cleanup

Delete the `aos-ansible` repository if desired
```
rm -rf ../aos-ansible
```


# Secret rotation

We use 2 types of secrets. Both of them contain the same data but in a different formats. 

```
-file - file based secret. It can be sourced by script (see ci-operator jobs code)
-env - environment based secret. It can be injected to pod using pod spec (see azure-purge code)
```

## File secret

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
oc create secret generic cluster-secrets-azure-file --from-file=cluster/test-deploy/azure/secret -o yaml --dry-run | oc apply -n ci -f -	
```

5. (Optional, if you dont have access to CI namespace)

```
oc apply secret generic cluster-secrets-azure-file --from-file=cluster/test-deploy/azure/secret -o yaml --dry-run | oc apply -n azure -f -
```

and ask somebody, who has access to execute:

```
oc get secret cluster-secrets-azure-file --export -n azure -o yaml | oc apply -f - -n ci
```

## Env secret

Rotate azure env secret:

```
source ./cluster/test-deploy/azure/secret
oc create secret generic cluster-secrets-azure-env --from-literal=azure_client_id=${AZURE_CLIENT_ID} --from-literal=azure_client_secret=${AZURE_CLIENT_SECRET} --from-literal=azure_tenant_id=${AZURE_TENANT_ID} --from-literal=azure_subscription_id=${AZURE_SUBSCRIPTION_ID} -o yaml --dry-run | oc apply -n azure -f -
```
