This repository holds OpenShift cluster manifests, component build manifests and CI workflow configuration for OpenShift component repositories for both OKD and OCP.

Task types:
- Modify CI jobs by editing files under `ci-operator/config/`. Always run `make jobs` afterwards to generate updates to `ci-operator/jobs/`.
- Modify steps (tasks you can call in jobs) in `step-registry/`.
