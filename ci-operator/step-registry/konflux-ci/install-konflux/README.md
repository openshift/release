# konflux-ci-install-konflux

Installs [Konflux](https://github.com/konflux-ci) on an OpenShift cluster using the
[infra-deployments](https://github.com/redhat-appstudio/infra-deployments) bootstrap scripts
in **preview mode**.

This step replaces the deprecated `redhat-appstudio-install-konflux` step, which relied on
magefiles from the [e2e-tests](https://github.com/konflux-ci/e2e-tests) repository.

## What it does

1. **Selects a GitHub account** with the highest remaining API rate limit from a pool of
   CI bot accounts.
2. **Logs into the cluster** using `kubeadmin` credentials from the claim.
3. **Clones `redhat-appstudio/infra-deployments`** at `main`. For presubmit jobs on
   infra-deployments PRs, the PR changes are merged into the working tree so the bootstrap
   runs against the proposed code.
4. **Marks master nodes as schedulable** (needed for small CI clusters).
5. **Runs `hack/bootstrap-cluster.sh preview`**, which deploys ArgoCD and bootstraps
   all Konflux components (host + member clusters, pipelines-as-code, build-service,
   integration-service, etc.).
6. **Creates the `e2e-secrets/quay-repository` secret** with Quay registry credentials
   required by build pipelines.
7. **Registers the PAC route with SprayProxy** so GitHub webhook events are forwarded
   to the ephemeral CI cluster.

## Credentials

The step mounts the `konflux-ci-secrets-new` secret from the `test-credentials` namespace at
`/usr/local/konflux-ci-secrets-new/redhat-appstudio-qe/`. Required keys:

| Key | Purpose |
|-----|---------|
| `github_accounts` | Comma-separated `user:token` pairs for GitHub API access |
| `default-quay-org-token` | Quay token for the `redhat-appstudio-qe` org (image-controller) |
| `quay-token` | Base64-encoded Docker config for Quay registry auth |
| `pac-github-app-id` | GitHub App ID for Pipelines-as-Code |
| `pac-github-app-private-key` | GitHub App private key (PEM) for Pipelines-as-Code |
| `pac-github-app-webhook-secret` | Webhook secret for the PAC GitHub App |
| `smee-channel` | Smee.io channel URL for webhook proxying |
| `qe-sprayproxy-host` | SprayProxy server URL |
| `qe-sprayproxy-token` | Bearer token for SprayProxy registration |

## Usage

Reference this step in a multi-stage test definition:

```yaml
tests:
- as: my-konflux-test
  cluster_claim:
    architecture: amd64
    cloud: aws
    owner: konflux
    product: ocp
    timeout: 1h0m0s
    version: "4.18"
  steps:
    test:
    - ref: konflux-ci-install-konflux
    - ref: redhat-appstudio-conformance-tests   # or your own test step
    workflow: redhat-appstudio-claim
```

## Infra-deployments PR support

When `REPO_NAME=infra-deployments` and `PULL_NUMBER` are set (standard Prow env vars for
presubmit jobs), the step automatically fetches and merges the PR into the infra-deployments
working tree before running bootstrap. This means presubmit tests validate the actual PR
changes without needing any extra configuration.

## Timeout

Default timeout is **1 hour**. The bootstrap process typically takes 15-25 minutes depending
on cluster size and image pull times.
