# Patched Deck build

On app.ci, `deck-history-bucket` builds [upstream Prow](https://github.com/kubernetes-sigs/prow)
at the Git revision embedded in the latest published Deck image, with
[d1d5cbef5ed31a1b6ef80c9faf7bfbc1b7c155ef](https://github.com/kubernetes-sigs/prow/commit/d1d5cbef5ed31a1b6ef80c9faf7bfbc1b7c155ef)
cherry-picked on top. This patch adds the history-bucket flags used by the
public Deck deployment.

The build runs every Monday at **03:00 UTC** (04:00 in Warsaw in winter,
05:00 in summer), and can be started manually. Each build fetches upstream
again with Docker layer caching disabled. It skips the cherry-pick if the
commit is already an ancestor of upstream or the exact patch is already
applied. Conflicts fail the build and require updating the patch.

The `ci/deck:upstream` image-stream tag mirrors upstream's published `deck:latest`
on a schedule. Its local reference policy serves the image through the CI
registry, so build pods pull only CI-registry images. The existing
`ci/deck:latest` tag is not changed.

The Go builder is
`registry.ci.openshift.org/openshift/release:rhel-9-release-golang-1.26-openshift-4.22`.
It reads `vcs.revision` from the upstream binary using `go version -m`, checks out
that exact revision, applies the patch, runs Deck's Go tests, and builds the
replacement binary. The runtime reuses the same upstream image, including its
frontend assets, templates, Spyglass lenses, git, and Kubernetes authentication
helpers. This patch changes only Go, so no Node.js, Yarn, or asset rebuild is
needed. Matching the source to the base image keeps the binary and assets
consistent. Missing upstream Git metadata fails the build. The binary's version
records the upstream SHA and patch SHA.

Successful builds publish `ci/deck:history-bucket`, available as
`registry.ci.openshift.org/ci/deck:history-bucket`. This is the image already
used by [public Deck](../../prow/03_deployment/deck.yaml). A failed build
leaves the previous image in place. Builds are serialized, and the weekly
trigger waits for completion so its Job also fails if the build fails.

The manifests are applied by the existing app.ci configuration deployment.
They depend on the existing `openshift/release` and `ci/deck` image streams;
only the dedicated `ci/deck:upstream` source tag is managed here.
The `admin_build-trigger_rbac.yaml` file must also be applied so the dedicated
`deck-build-trigger` service account can start this build and read its status
and logs. The build itself uses the namespace's existing `builder` service
account to publish to the internal registry; no new registry credentials
are needed.

After the upstream mirror has imported successfully, build immediately with an
app.ci context:

```sh
oc --context=app.ci --namespace=ci get imagestreamtag deck:upstream
oc --context=app.ci --namespace=ci start-build deck-history-bucket --follow --wait
```

To inspect scheduled runs:

```sh
oc --context=app.ci --namespace=ci get cronjob trigger-deck-history-bucket-build
oc --context=app.ci --namespace=ci get builds -l buildconfig=deck-history-bucket
```

Building updates the image tag. To load it into running public Deck pods:

```sh
oc --context=app.ci --namespace=ci rollout restart deployment/deck
oc --context=app.ci --namespace=ci rollout status deployment/deck
```
