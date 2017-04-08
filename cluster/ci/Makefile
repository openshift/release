
deploy:
	-oc apply -f config/
	oc replace -n default -f data/router-certs-secret.json
	oc extract -n default $$(oc get secrets -n default -o name | grep router-token | head -1) --keys service-ca.crt --to /tmp --confirm
	oc delete -n default route docker-registry
	oc create route reencrypt -n default --dest-ca-cert=/tmp/service-ca.crt --hostname=registry.svc.ci.openshift.org --service=docker-registry
	oc rollout latest -n default router
	oadm policy add-cluster-role-to-user -z heapster -n kube-system cluster-reader
	oc process heapster-standalone | oc apply -f - -n kube-system
