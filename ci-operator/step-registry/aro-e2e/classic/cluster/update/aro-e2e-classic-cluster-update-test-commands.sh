#get cluster Kubeadmin and login from shared dir
kubectl set context --kubeconfig ${SHARED_DIR}/kubeconfig
#get pull secret
oc get secret/pull-secret -n openshift-config -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d > existing-pull-secret.json
jq -s '.[0] * .[1]' existing-pull-secret.json /run/secrets/ci.openshift.io/cluster-profile/pull-secret > merged-pull-secret.json
#Set Pull secret
oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson=merged-pull-secret.json

#change the upgrade channel and patch CVO to desired version
