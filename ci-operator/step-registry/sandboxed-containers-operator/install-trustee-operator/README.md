# install-trustee-operator

If `TRUSTEE_INSTALL: "true"` and `HELM_CHART_IMAGE` is set to a prebuilt image in a container repo, this step installs the [Trustee operator](https://github.com/confidential-containers/trustee) and its operands on an OpenShift cluster for Confidential Containers (CoCo) testing.

Helm charts from [confidential-devhub/charts](https://github.com/confidential-devhub/charts) are rendered with `helm template` and applied via `oc apply`.

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
Build arguments let you pin the helm version, charts repository, and branch
at build time. You can use the upstream
[confidential-devhub/charts](https://github.com/confidential-devhub/charts)
repo or your own fork.

```dockerfile
FROM registry.access.redhat.com/ubi9/ubi-minimal:latest

RUN microdnf install -y git tar gzip jq && microdnf clean all
RUN cp -L /lib64/libjq.so.1 /lib64/libonig.so.5 /usr/local/lib/

ARG HELM_VERSION=v3.17.3
RUN curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" | \
    tar xz -C /usr/local/bin --strip-components=1 linux-amd64/helm && \
    helm version

ARG CHARTS_REPO=https://github.com/confidential-devhub/charts
ARG CHARTS_BRANCH=main
RUN git clone --depth 1 --branch "${CHARTS_BRANCH}" \
      "${CHARTS_REPO}" /tmp/charts-repo && \
    cp -a /tmp/charts-repo/charts /charts && \
    rm -rf /tmp/charts-repo

RUN ls /charts/trustee-operator /charts/trustee-operands
```

| Build Arg | Default | Description |
|-----------|---------|-------------|
| `HELM_VERSION` | `v3.17.3` | Helm binary version to install. |
| `CHARTS_REPO` | `https://github.com/confidential-devhub/charts` | Git URL of the charts repository. Use a fork URL to test chart changes before merging upstream. |
| `CHARTS_BRANCH` | `main` | Branch or tag to check out from `CHARTS_REPO`. |

Build and push to the Quay registry and tag of your choice:

```bash
# Set these to your own values
#HELM_VERSION=v3.16.4
#CHARTS_REPO=https://github.com/confidential-devhub/charts
#CHARTS_BRANCH=main
USER=tbuskey
REGISTRY=quay.io/$USER         # your registry and namespace
IMAGE_NAME=trustee-helm-charts # image name
IMAGE_TAG=latest               # image tag

# Build from upstream charts (defaults)
podman build -t ${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG} .


# Build from a fork and branch and override default helm repo
podman build \
  --build-arg HELM_VERSION=$HELM_VERSION \
  --build-arg CHARTS_REPO=$CHARTS_REPO \
  --build-arg CHARTS_BRANCH=$CHARTS_BRANCH \
  -t ${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG} .

# Push the image
podman push ${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}
HELM_CHART_IMAGE=${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}
echo $HELM_CHART_IMAGE
```

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
   and image security policy. The `image_security_policy` defaults to
   rejecting all images except `ghcr.io/confidential-containers/test-container-image-rs`,
   which is allowed via `sigstoreSigned` verification (with `matchRepository`
   identity) or `insecureAcceptAnything` as a fallback. KBS URLs in
   `aa.toml` and `cdh.toml` use `https` for TLS-secured communication.
8. Updates the `osc-config` ConfigMap in the `default` namespace.
9. Verifies KBS connectivity with a kbs-client test pod (RCA protocol).
10. Saves KBS attestation logs to `${ARTIFACT_DIR}/kbs-attestation-logs.txt`.

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
      HELM_CHART_IMAGE: quay.io/$ORG/trustee-helm-charts:v1.13
      TRUSTEE_INSTALL: "true"
      TRUSTEE_CATALOG_SOURCE_IMAGE: quay.io/redhat-user-workloads/ose-osc-tenant/trustee-test-fbc:latest
    workflow: sandboxed-containers-operator-e2e-azure
```
