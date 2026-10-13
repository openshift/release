# Patched Deck build

On app.ci, `deck-history-bucket` builds the current `main` branch of
[upstream Prow](https://github.com/kubernetes-sigs/prow) with
[d1d5cbef5ed31a1b6ef80c9faf7bfbc1b7c155ef](https://github.com/kubernetes-sigs/prow/commit/d1d5cbef5ed31a1b6ef80c9faf7bfbc1b7c155ef)
cherry-picked on top. This patch adds the history-bucket flags used by the
public Deck deployment.

The build runs on configuration changes and every Monday at **03:00 UTC**
(04:00 in Warsaw in winter, 05:00 in summer). Each build fetches upstream
again with Docker layer caching disabled. It skips the cherry-pick if the
commit is already an ancestor of upstream or the exact patch is already
applied. Conflicts fail the build and require updating the patch.

The build runs Deck's Go tests, gathers its frontend assets and Spyglass
lenses using upstream's `gather-static.sh`, and builds the Deck binary.
The runtime base matches upstream's `.ko.yaml`; keep it current when
upstream changes that base. The binary's version records the upstream SHA
and patch SHA.

Successful builds publish `ci/deck:history-bucket`, available as
`registry.ci.openshift.org/ci/deck:history-bucket`. This is the image already
used by [public Deck](../../prow/03_deployment/deck.yaml). A failed build
leaves the previous image in place. Builds are serialized, and the weekly
trigger waits for completion so its Job also fails if the build fails.

The manifests are applied by the existing app.ci configuration deployment.
The `admin_build-trigger_rbac.yaml` file must also be applied so the dedicated
`deck-build-trigger` service account can start this build and read its status
and logs. The build itself uses the namespace's existing `builder` service
account to publish to the internal registry; no new registry credentials
are needed.

To build immediately, with an app.ci context:

```sh
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
