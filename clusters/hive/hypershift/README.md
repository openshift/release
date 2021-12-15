# Hypershift

This directory contains manifests for a Hypershift setup that is used in CI.

How to update the version:

1. Tag a Hypershift image to make sure it doesn't get garbage collected:
    * Find the commmit for the current `latest` image: `oc get imagestreamtag -n hypershift hypershift:latest -oyaml|grep io.openshift.build.commit.id`
		* Tag it: `oc tag -n hypershift hypershift:latest hypershift:$COMMIT_FROM_PREVIOUS_COMMAND`
1. Render the manifests with the correct image: `hypershift install --oidc-storage-provider-s3-credentials=/dev/null  --oidc-storage-provider-s3-bucket-name=hypershift-ci-oidc --oidc-storage-provider-s3-region=us-east-1 --render --hypershift-image=registry.ci.openshift.org/hypershift/hypershift:$TAG_FROM_PREVIOUS_COMMAND > clusters/hive/hypershift/hypershift.yaml`
1. Remove the `hypershift-operator-oidc-provider-s3-credentials` secret from the generated manifests, this is managed through vault (https://vault.ci.openshift.org/ui/vault/secrets/kv/show/selfservice/hypershift-team/aws-oidc-credential)
