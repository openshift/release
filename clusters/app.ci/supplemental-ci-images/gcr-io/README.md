TODO
====

Since the upstream Prow team advice us to not pull these images from `staging`, `gcr` or otherwise, we decided, temporarily, to build these images internally.

This process will be active until we know what will happen with the upstream images.

Images
------

These images are build using `BuildConfig` and `CronJob`:

- `gcr.io/distroless/static:nonroot`
- `gcr.io/kubebuilder/kube-rbac-proxy`
- `gcr.io/k8s-prow/commenter`
- `gcr.io/istio-testing/build-tools`
- `gcr.io/envoy-ci/envoy-build`
- `gcr.io/k8s-staging-test-infra/git`
- `gcr.io/k8s-staging-test-infra/gcsweb`
- `gcr.io/k8s-staging-test-infra/label_sync`
- `gcr.io/k8s-staging-boskos/reaper`
- `gcr.io/k8s-staging-boskos/cleaner`
- `gcr.io/k8s-staging-boskos/checkconfig`
