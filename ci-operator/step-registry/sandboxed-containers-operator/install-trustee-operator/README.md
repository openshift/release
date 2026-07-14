# install-trustee-operator

Installs the [Trustee operator](https://github.com/confidential-containers/trustee) and
its operands on an OpenShift cluster for Confidential Containers (CoCo) testing.

Helm charts from [confidential-devhub/charts](https://github.com/confidential-devhub/charts)
are rendered with `helm template` and applied via `oc apply`.

## Chart Delivery

The step requires a pre-built container image (`HELM_CHART_IMAGE`) containing
the `helm` binary and the `trustee-operator` / `trustee-operands` helm charts.
At runtime the step extracts both with:

```
oc image extract $HELM_CHART_IMAGE \
  --path /charts/:<scratch>/ \
  --path /usr/local/bin/helm:<scratch>/bin/
```

Because `oc image extract` pulls through the cluster (not the step pod's
network), this works with `restrict_network_access: true` -- making it safe
for Konflux jobs and pj-rehearse.

The image must provide:

- **helm** at `/usr/local/bin/helm`
- **jq** at `/usr/bin/jq`
- **charts** at `/charts/` with the following layout:

```
/charts/
  trustee-operator/
    Chart.yaml
    values.yaml
    templates/
  trustee-operands/
    Chart.yaml
    values.yaml
    templates/
```

## Building the Helm Chart Image

Create a `Containerfile` (or `Dockerfile`) with the content below.
Build arguments let you pin the helm version and chart ref at build time.

```dockerfile
FROM registry.access.redhat.com/ubi9/ubi-minimal:latest

RUN microdnf install -y git tar gzip jq && microdnf clean all

ARG HELM_VERSION=v3.17.3
RUN curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" | \
    tar xz -C /usr/local/bin --strip-components=1 linux-amd64/helm && \
    helm version

ARG CHARTS_TAG=main
RUN git clone --depth 1 --branch "${CHARTS_TAG}" \
      https://github.com/confidential-devhub/charts /tmp/charts-repo && \
    cp -a /tmp/charts-repo/charts /charts && \
    rm -rf /tmp/charts-repo

RUN ls /charts/trustee-operator /charts/trustee-operands
```

Build and push to the registry and tag of your choice:

```bash
# Defaults (helm v3.17.3, charts from main)
podman build -t quay.io/$ORG/trustee-helm-charts:latest .

CHARTS_TAGS=main
IMAGE_VERSION=v1.13
ORG=tbuskey

# Pin a specific chart ref
podman build \
  --build-arg CHARTS_TAG=$CHARTS_TAG \
  -t quay.io/$ORG/trustee-helm-charts:$IMAGE_VERSION .

# Override helm version too
podman build \
  --build-arg HELM_VERSION=v3.16.4 \
  --build-arg CHARTS_TAG=$CHARTS_TAG \
  -t quay.io/$ORG/trustee-helm-charts:$IMAGE_VERSION .

podman push quay.io/$ORG/trustee-helm-charts:$IMAGE_VERSION
```

Replace `$ORG` with your Quay.io organization or any other registry you
control.

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `HELM_CHART_IMAGE` | _(empty)_ | **Required when `TRUSTEE_INSTALL=true`.** Pre-built image containing helm at `/usr/local/bin/helm` and charts at `/charts/`. Both are extracted from this image; no external network access is needed. |
| `TRUSTEE_INSTALL` | `false` | Set to `true` to run the installation. When `false` the step exits immediately. |
| `TRUSTEE_NAMESPACE` | `trustee-operator-system` | Namespace for the operator and operands. |
| `TRUSTEE_CATALOG_SOURCE_IMAGE` | _(empty)_ | Custom CatalogSource image. If empty, uses the existing `redhat-operators` catalog. If set, the helm chart creates a `trustee-operator-dev-catalog` CatalogSource (name is hardcoded in the chart). |
| `KBS_CLIENT_TAG` | _(empty)_ | kbs-client image tag for connectivity testing. Auto-discovered via skopeo when empty; fallback `v0.19.0`. |

## What the Step Does

1. Extracts helm binary and charts from `HELM_CHART_IMAGE`.
2. Renders `trustee-operator` chart with `helm template` and applies it.
3. Waits for OLM installation stages: CatalogSources READY, Subscription,
   InstallPlan, CSV Succeeded, Deployment Available, pods Ready.
4. Renders `trustee-operands` chart (parameterized with the cluster domain)
   and applies it.
5. Waits for operand deployments to become available.
6. Discovers the KBS service URL (route, LoadBalancer, or ClusterIP).
7. Creates INITDATA (aa.toml, cdh.toml, policy.rego) with TLS certificate
   and image security policy.
8. Updates the `osc-config` ConfigMap in the `default` namespace.
9. Verifies KBS connectivity with a kbs-client test pod (RCA protocol).
10. Saves KBS attestation logs to `${ARTIFACT_DIR}/kbs-attestation-logs.txt`.

## Outputs

Written to `${SHARED_DIR}` for use by subsequent steps:

| File | Content |
|------|---------|
| `TRUSTEE_URL` | KBS service URL (e.g. `http://kbs-service-trustee-operator-system.apps.example.com`) |
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
      HELM_CHART_IMAGE: quay.io/$ORG/trustee-helm-charts:v1.2.0
      TRUSTEE_INSTALL: "true"
      TRUSTEE_CATALOG_SOURCE_IMAGE: quay.io/redhat-user-workloads/ose-osc-tenant/trustee-test-fbc:latest
    workflow: sandboxed-containers-operator-e2e-azure
```
