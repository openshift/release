# install-trustee-operator

If `TRUSTEE_INSTALL: "true"`, this step installs the [Trustee operator](https://github.com/confidential-containers/trustee) and its operands on an OpenShift cluster for Confidential Containers (CoCo) testing.

Helm charts from [confidential-devhub/charts](https://github.com/confidential-devhub/charts) are cloned at runtime and rendered with `helm template`, then applied via `oc apply`.

## Chart Delivery

The step clones the charts repository directly using `git clone`:

```bash
git clone --depth 1 --branch "${TRUSTEE_CHARTS_REF}" "${TRUSTEE_CHARTS_REPO}" <scratch>/charts
```

The `helm` binary and other tools (`oc`, `git`, `jq`) are provided by the
`rhdh-e2e-runner` base image specified in the ref definition.

The cloned repository must contain:

```
charts/
  trustee-operator/
    Chart.yaml
    values.yaml
    templates/
  trustee-operands/
    Chart.yaml
    values.yaml
    templates/
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `TRUSTEE_INSTALL` | `false` | Set to `true` to run the installation. When `false` the step exits immediately. |
| `TRUSTEE_NAMESPACE` | `trustee-operator-system` | Namespace for the operator and operands. |
| `TRUSTEE_CHARTS_REPO` | `https://github.com/confidential-devhub/charts.git` | Git repository URL for trustee Helm charts. Use a fork URL to test chart changes before merging upstream. |
| `TRUSTEE_CHARTS_REF` | `main` | Git ref (branch, tag, or commit) to check out from `TRUSTEE_CHARTS_REPO`. |
| `TRUSTEE_CATALOG_SOURCE_IMAGE` | _(empty)_ | Custom CatalogSource image. If empty, uses the existing `redhat-operators` catalog. If set, the helm chart creates a `trustee-operator-dev-catalog` CatalogSource (name is hardcoded in the chart). |
| `KBS_CLIENT_TAG` | `v0.19.0` | kbs-client image tag for connectivity testing. |

## What the Step Does

1. Clones helm charts from `TRUSTEE_CHARTS_REPO` at ref `TRUSTEE_CHARTS_REF`.
2. Renders `trustee-operator` chart with `helm template` and applies it.
3. Waits for OLM installation stages: CatalogSources READY, Subscription,
   InstallPlan, CSV Succeeded, Deployment Available, pods Ready.
4. Renders `trustee-operands` chart (parameterized with the cluster domain)
   and applies it.
5. Creates the `kbsres1` secret (cosign public key) required by the KbsConfig
   controller and patches it into the KbsConfig CR's `kbsSecretResources`.
6. Waits for operand deployments to become available.
7. Discovers the KBS service URL (route, LoadBalancer, or ClusterIP).
8. Creates INITDATA (aa.toml, cdh.toml, policy.rego) with TLS certificate
   and image security policy. The `image_security_policy` is read from the
   `containers-policy` secret if available; otherwise defaults to rejecting
   all images except `ghcr.io/confidential-containers/test-container-image-rs`,
   which is allowed via `sigstoreSigned` verification (with `matchRepository`
   identity) or `insecureAcceptAnything` as a fallback. KBS URLs in
   `aa.toml` and `cdh.toml` use `https` for TLS-secured communication.
9. Updates the `osc-config` ConfigMap in the `default` namespace.
10. Verifies KBS connectivity with a kbs-client test pod (RCA protocol) by
    retrieving `default/kbsres1/key1` via in-cluster HTTP and validating the
    returned value matches the configured secret.
11. Saves KBS attestation logs to `${ARTIFACT_DIR}/kbs-attestation-logs.txt`.

## Outputs

Written to `${SHARED_DIR}` for use by subsequent steps:

| File | Content |
|------|---------|
| `TRUSTEE_URL` | KBS service URL (e.g. `https://kbs-service-trustee-operator-system.apps.example.com`) |
| `TRUSTEE_HOST` | KBS hostname |
| `TRUSTEE_PORT` | KBS port |
| `INITDATA` | Base64-encoded gzipped `initdata.toml` |
| `initdata.toml` | Plain text initdata configuration |

## CI Config Example

```yaml
tests:
- as: my-coco-test
  restrict_network_access: true
  steps:
    env:
      TRUSTEE_INSTALL: "true"
      TRUSTEE_CHARTS_REPO: https://github.com/confidential-devhub/charts.git
      TRUSTEE_CHARTS_REF: main
      TRUSTEE_CATALOG_SOURCE_IMAGE: quay.io/redhat-user-workloads/ose-osc-tenant/trustee-test-fbc:latest
    workflow: sandboxed-containers-operator-e2e-azure
```
