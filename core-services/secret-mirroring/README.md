# Secret Mirroring

This directory contains deployment manifests and configuration for the
[ci-secret-mirroring-controller](https://github.com/openshift/ci-secret-mirroring-controller).
This tool mirrors secrets from one location in the cluster to another, allowing
users to provide secrets without requiring RBAC privileges on secrets in a central
namespace.

Note that the tool can mirror secrets from a source to the target on the same cluster and 
is deployed on all the clusters in the CI-infrastructure.
Please ensure that the source secrets are available on all the clusters, in
order to mirror them to the targets on all the clusters.

# Self-managed secrets

In order to provide custom secrets to jobs without putting the secret management
into the hands of the Developer Productivity (Test Platform) team, it is possible
to create the secrets in the cluster and have them automatically mirrored to be
available for jobs. This is useful when:

 - the secret owners do not wish to upload them to BitWarden
 - the secrets have dynamic lifecycles and the owners need to rotate them frequently

First, create a secret in a self-managed namespace:

```sh
oc new-project my-kerbID-secrets
oc create secret --namespace my-kerbID-secrets generic my-secret --from-file secret.txt 
```

Then, update the [secret mirroring configuration](./_mapping.yaml) in this directory
to mirror the secret that was just created into the namespaces where jobs run:

```yaml
secrets:
- from:
    namespace: my-kerbID-secrets
    name: my-secret
  to:
    namespace: ci
    name: my-secret
- from:
    namespace: my-kerbID-secrets
    name: my-secret
  to:
    namespace: ci-stg
    name: my-secret
```
