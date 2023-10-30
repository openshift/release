oc create namespace $WMCO_DEPLOY_NAMESPACE
oc label --overwrite=true ns $WMCO_DEPLOY_NAMESPACE openshift.io/cluster-monitoring=true \
pod-security.kubernetes.io/enforce=privileged
if [ -z "$OO_OPERATOR" ]; then
  operator-sdk run bundle --timeout=10m --security-context-config restricted -n $WMCO_DEPLOY_NAMESPACE "$OO_BUNDLE"
  oc wait --timeout=5m --for condition=Available -n $WMCO_DEPLOY_NAMESPACE deployment windows-machine-config-operator
  exit 0
fi

# If OO_OPERATOR is set, patch the bundle to override the WMCO image used within it. This is necessary when using a
# bundle image, outside of the pipeline the bundle image was built. This is because the bundle will be using an image
# which is not usable outside that pipeline's context.
operator-sdk run bundle --timeout=10m --security-context-config restricted -n $WMCO_DEPLOY_NAMESPACE "$PREVIOUS_BUNDLE" \
|| oc get csv -n $WMCO_DEPLOY_NAMESPACE |awk {'print $1'} | tail -n1 | xargs oc patch csv -n $WMCO_DEPLOY_NAMESPACE --type='json' \
-p="[{\"op\": \"replace\", \"path\": \"/spec/install/spec/deployments/0/spec/template/spec/containers/0/image\", \"value\": \"$PREVIOUS_OPERATOR\"}]"
sleep 10
# Delete the deployment which will then be recreated by the subscription controller with the correct image
oc delete deployment -n $WMCO_DEPLOY_NAMESPACE windows-machine-config-operator
# oc wait will immediately fail if the deployment does not exist yet, first retry until the deployment is
# created by the subscription controller
retries=0
while ! oc get -n $WMCO_DEPLOY_NAMESPACE deployment windows-machine-config-operator; do
  if [[ $retries -eq 10 ]]; then
    echo max retries hit
    exit 1
  fi
  sleep 1m
  retries=$((retries+1))
done
oc wait --timeout=10m --for condition=Available -n $WMCO_DEPLOY_NAMESPACE deployment windows-machine-config-operator