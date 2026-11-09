# OpenShift Prow instance

Manifests and configuration of the OpenShift instance of [Prow](https://github.com/kubernetes/test-infra/blob/master/prow/README.md)
running on the api.ci cluster.

The [dispatcher dashboard rollout](dispatcher-dashboard.md) covers its image,
credentials, authenticated route, and validation.

Production Deck and Gangway Deployments are plain YAML documents in the existing
component files in `03_deployment/`, separated from their OpenShift Templates by
`---`, so Argo CD can apply changes to their job config paths and volumes. Each
reads both the Git checkout and the read-only
`job-configs-nfs` EFS volume. Their main container images also track Git so that
job config flags are deployed with a compatible Prow version.

The corresponding OpenShift Templates retain the routes, services, and generated
OAuth session secrets. Argo CD stores these Templates without processing their
objects; keep Deployment definitions as separate YAML documents.
