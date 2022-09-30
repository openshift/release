HyperShift deployment on Hive

* Management cluster (hive)
The management cluster requries some configurations in AWS
before K8s configurations are applied. We need to:
1. Deploy management_cluster.cf
2. Gather the AWS credentials from Secret Manager
3. Update AWS credential in value (`dptp/hypershift/operator-oidc-provider-s3-credentials`)

Once the secret is updated, we can go ahead to deploy the main yaml file (`hypershift-operator.yaml`). We might need to apply this file multiple times,
since it includes both installation of `multicluster operator` and CRDs which are not available before the `multicluster operator` is installed.

* AWS accounts for hosted cluster
The worker nodes of hosted cluster are running in this AWS account.
Also, configurations of the AWS account is required.
1. Deploy hosted_clusters.cf
2. Gather the AWS credentials from Secret Manager
3. Update AWS credential in value (e.g., `dptp/hypershift/aws-2`)
3.a. the `pullSecret` is obtained from [OSD console](https://console.redhat.com/openshift/token)
