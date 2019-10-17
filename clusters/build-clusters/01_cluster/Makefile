#Reusing the pull secret from secret -n ci cluster-secrets-aws
#It requires that oc-cli logs in api.ci.openshift.org
pull_secret := $(shell oc get secret -n ci cluster-secrets-aws -o jsonpath='{.data.pull-secret}' | base64 -d)

.PHONY : generate-install-config
generate-install-config:
	@echo "generating install config ..."
	@echo "replacing the pull secret in install-config.yaml ..."
	@sed -e 's|{{ pull_secret }}|$(pull_secret)|g' ./install-config.yaml > /tmp/install-config.yaml
	@echo "run 'cp /tmp/install-config.yaml ~/install-config.yaml' before installing the cluster"

release_image := registry.svc.ci.openshift.org/ocp/release:4.2.0-0.nightly-2019-10-11-230724

.PHONY : install-dptp-managed-cluster
install-dptp-managed-cluster:
	@echo "install dptp-managed cluster ..."
	./install_cluster.sh $(release_image)
