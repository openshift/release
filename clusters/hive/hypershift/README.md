This directory includes the manifests, including the generated ones, for deploying HyperShift on the `hive` cluster.

# HyperShift CLI and operator images
[HyperShift CLI](https://hypershift-docs.netlify.app/getting-started/) which is the utility for installing HyperShift as well as creating and destroying hosted clusters and the HyperShift operator which is the core component running on HyperShift management cluster share the same image. 
They must have the exact same version to work properly [HOSTEDCP-792](https://issues.redhat.com/browse/HOSTEDCP-792).

The image is built with [hypershift-cli.yaml](clusters/app.ci/supplemental-ci-images/hypershift/hypershift-cli.yaml). The purposes of the build are
- add useful utilities, e.g., `jq`, and
- save a stable tag as explained before.

# Deployment/upgrading on `hive`
Prepare the AWS credentials for your management cluster account (in this case, the AWS account running `hive` cluster) in `~/workspace/mgmt-aws` (or any other path you prefer).

Generate the Hypershift deployment manifest `hypershift.yaml`:
```
docker run -ti --rm -v ~/workspace/mgmt-aws:/mgmt-aws:ro registry.ci.openshift.org/ci/hypershift-cli:<tag> install --oidc-storage-provider-s3-bucket-name=hypershift-oidc-provider --oidc-storage-provider-s3-credentials=/mgmt-aws --oidc-storage-provider-s3-region=us-east-1 --hypershift-image=https://registry.ci.openshift.org/ci/hypershift-cli:<tag> --enable-uwm-telemetry-remote-write=false render > hypershift-install.yaml
```

The image in parameter `--hypershift-image` must have the SAME as the one invoking the command.

Then apply the file with
`oc --context hive apply -f hypershift.yaml --server-side`

Dont forget to update the workflow (`ci-operator/step-registry/hypershift/hostedcluster/create/hostedcluster/hypershift-hostedcluster-create-hostedcluster-ref.yaml`) to use the new image.

# Note
!!! IMPORTANT !!!
The CLI used to generate the deployment file must be the _EXACT_ CLI used to create/destroy hosted cluster.
