# OSSM Service Mesh automation

The weekday Istio z-stream release-branch job processes only the latest stable
patch tag for upstream Istio minor versions 1.30 and 1.31. These versions are
hard-coded in the `supported_versions` array in
`ci-operator/step-registry/servicemesh/istio/release-branches/servicemesh-istio-release-branches-commands.sh`.

When a new minor version becomes supported, update that array and remove the
version that has dropped out of support. See the
`servicemesh-istio-release-branches` step for how branch points are chosen.
