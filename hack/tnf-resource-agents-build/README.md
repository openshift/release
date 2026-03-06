# Local build test (CentOS Stream 9 and 10)

Verifies the resource-agents build works on CentOS Stream 9 and 10. Images are built and tagged in the local registry only (no push).

Run from the release repo root or from this directory:

```bash
./hack/tnf-resource-agents-build/local-build-test.sh
# or
cd hack/tnf-resource-agents-build && ./local-build-test.sh
```

Produces:
- `localhost/tnf-resource-agents-build:stream9` — full RPM build (EPEL provides libqb-devel).
- `localhost/tnf-resource-agents-build:stream10` — source build only; `make rpm` is skipped because libqb-devel is not in EPEL 10 (libqb is built from source for configure/make).

Build manually from `hack/tnf-resource-agents-build/`:
- `podman build -f Dockerfile.stream9 -t localhost/tnf-resource-agents-build:stream9 .`
- `podman build -f Dockerfile.stream10 -t localhost/tnf-resource-agents-build:stream10 .`
