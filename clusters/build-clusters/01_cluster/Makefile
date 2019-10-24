.PHONY: all
all:
	#TODO (hongkliu)
	@echo "target 'all' has not yet implemented"

#Reusing the pull secret from secret -n ci cluster-secrets-aws
#It requires that oc-cli logs in api.ci.openshift.org
pull_secret := $(shell oc get secret -n ci cluster-secrets-aws -o jsonpath='{.data.pull-secret}' | base64 -d)

.PHONY : generate-install-config
generate-install-config:
	@echo "generating install config ..."
	@echo "replacing the pull secret in install-config.yaml ..."
	@sed -e 's|{{ pull_secret }}|$(pull_secret)|g' ./_install/install-config.yaml > /tmp/install-config.yaml
	@echo "run 'cp /tmp/install-config.yaml ~/install-config.yaml' before installing the cluster"

#TODO (hongkliu): rest api for lastest
release_image := registry.svc.ci.openshift.org/ocp/release:4.2.0-0.nightly-2019-10-11-230724

.PHONY: install-dptp-managed-cluster
install-dptp-managed-cluster:
	@echo "installing dptp-managed cluster ..."
	./_install/install_cluster.sh $(release_image)

###pip install --user yq
secret_file := "/tmp/secret.yaml"
client_id := $(shell yq -r .github.client_id $(secret_file))
client_secret := $(shell yq -r .github.client_secret $(secret_file))

.PHONY: set-up-github-oauth
set-up-github-oauth:
	@echo "set up github oauth ..."
	@oc process -f ./assets/github-client-secret_secret_template.yaml -p github_client_secret=$(client_secret) | oc apply -n openshift-config -f -
	@oc process -f ./assets/admin_cluster_oauth_template.yaml -p github_client_id=$(client_id) | oc apply -f -

.PHONY: set-up-ci-admins
set-up-ci-admins:
	@echo "setting up ci-admins"
	oc create -f ./assets/admin_cluster-admin-0_list.yaml

### assume first 3 machinesets are the same for masters
### we can check by: oc get machines -n openshift-machine-api | grep master
### they should be the same as the generated files
.PHONY: generate-machine-autoscaler
generate-machine-autoscaler:
	@echo "generating machine-autoscaler ..."
	@declare -a arr=( $$(oc get MachineSet -n openshift-machine-api -o yaml | yq -r .items[].metadata.name | head -n 3)); for machineset_name in "$${arr[@]}"; \
	do \
	  echo "set up machineautoscaler for $${machineset_name}"; \
	  echo "replacing the machineset_name in machineautoscaler.yaml ..."; \
	  sed -e "s|{{ machineset_name }}|$${machineset_name}|g" ./_assets/machineautoscaler.yaml > "./assets/$${machineset_name}_machineautoscaler.yaml"; \
	done

.PHONY: set-up-autoscaler
set-up-autoscaler:
	@echo "setting up autoscaler ..."
	oc apply -f ./assets/admin_default_clusterautoscaler.yaml
	find ./assets -name "*_machineautoscaler.yaml" -exec oc apply -f {} \;
