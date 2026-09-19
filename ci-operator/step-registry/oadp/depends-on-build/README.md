# oadp-depends-on-build-ref<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->

- [Purpose](#purpose)
- [Process](#process)
  - [Trigger semantics for a multi-repo PR author](#trigger-semantics-for-a-multi-repo-pr-author)
  - [Worked example: oadp-operator depending on oadp-non-admin](#worked-example-oadp-operator-depending-on-oadp-non-admin)
  - [Environment Variables](#environment-variables)
  - [Output](#output)
- [Known limitations](#known-limitations)
- [Provenance](#provenance)

## Purpose

Lets a CI job testing one repo's PR also pull in an unmerged PR from one or more sibling repos, via a `Depends-On:` line in the triggering PR's own description -- the same PR-description convention already used by `openstack-k8s-operators-kuttl-commands.sh`. Unlike that step (a plain source checkout), a resolved dependency here becomes a real pushed container image, because downstream needs an actual pullspec (e.g. a Kubernetes `Subscription`'s `RELATED_IMAGE_*` override).

Written generically to cover the N-repo case tracked by [openshift/oadp-operator#2389](https://github.com/openshift/oadp-operator/issues/2389) ("test oadp-operator + kdm-controller + kdm-plugin + velero-plugin-for-aws etc. together"). Consumed by:

- The 4 `migtools/kubevirt-datamover-{controller,plugin}` (KDM) e2e configs (`oadp-dev`/`oadp-1.6`). The plugin configs declare 2 candidates (the sibling controller repo, and `openshift/velero` itself -- e.g. testing a plugin PR against an unmerged velero PR that changes how it calls `Execute()`/other plugin-interface functions); the controller configs declare 2 as well (the sibling plugin repo, and `openshift/oadp-operator` via the `MANAGER_IMAGE` sentinel below). See [openshift/oadp-operator#1832](https://github.com/openshift/oadp-operator/issues/1832) for the KDM e2e coverage this builds on.
- `openshift/oadp-operator`'s own `e2e-test-aws`, across all 10 branch/OCP-version configs from `oadp-1.4` through `oadp-dev`, each declaring one candidate per `RELATED_IMAGE_*` its bundle substitutes (the exact set varies per branch -- older branches ship fewer components) -- see [`oadp-apply-depends-on-images`](../apply-depends-on-images/README.md) for how a resolved image actually takes effect there (an OLMv0 Subscription patch, with an explicit seam for future OLMv1/operator-controller support).
- `openshift/velero`, `openshift/velero-plugin-for-aws`, `openshift/velero-plugin-for-legacy-aws`, and `openshift/openshift-velero-plugin`'s own new `e2e-test-aws` jobs (4 branches each, `oadp-1.4` through `oadp-dev`: 16 configs total). Unlike KDM's `TEST_VIRT_KDM=true` or oadp-operator's own full-bundle build, these install a plain, unmodified oadp-operator bundle (`oadp-operator-sdk-bundle-image`) and run the operator's **default** `make test-e2e` suite with no component flag -- every one of these 4 repos is already exercised by the default (non-`virt`/`hcp`/`cli`) backup/restore specs, so no dedicated spec selection is needed. Each of the 4 declares the other 3 as candidates plus `openshift/oadp-operator MANAGER_IMAGE`, so any pairing/triple/full-quad combo among them (plus an oadp-operator reconcile-logic change) is triggerable from any one of the 4 PRs. `openshift/velero-plugin-for-microsoft-azure` and `openshift/velero-plugin-for-gcp` are intentionally not included in this round. `migtools/kubevirt-velero-plugin` and `openshift/hypershift-oadp-plugin` are also not included -- both need a non-default test flag (`TEST_VIRT`/`TEST_HCP`) with its own expensive cluster setup (KubeVirt/HyperShift), so a "normal" job here wouldn't actually exercise them.

## Process

1. Reads the triggering PR's description via the GitHub API, using Prow's own injected `REPO_OWNER`/`REPO_NAME`/`PULL_NUMBER` (no JSON parsing needed to identify the PR itself).
2. Scans it for every `Depends-On: https://github.com/<org>/<repo>/pull/<N>` line (Gerrit/Zuul convention, one per line).
3. For each line whose `<org>/<repo>` matches an entry in `DEPENDS_ON_CANDIDATES`: fetches that PR's source as a GitHub tarball (no `git` dependency), builds it as a container image via an OpenShift binary `Build` (`oc new-build --strategy=docker --binary` + `oc start-build --from-dir=...`) running **inside the target test cluster**, and records the result.
4. A PR with no matching `Depends-On:` line for any configured candidate is a total no-op -- nothing is built, nothing is written, no other step's behavior changes.

Building runs entirely inside the target cluster as a normal OpenShift `Build` (buildah managed by OCP -- nothing to install locally), landing in that cluster's own internal registry as an `ImageStreamTag`. No external route, insecure-registry marking, or `MachineConfigPool` rollout is needed here, unlike `oadp-operator-sdk-bundle-image`'s `OO_MIRROR_TO_CLUSTER_REGISTRY` -- the only consumer of this image is that same cluster's own kubelet, which already trusts its internal registry natively.

### Trigger semantics for a multi-repo PR author

- **Only the triggering PR needs a `Depends-On:` line.** The depended-on PR needs no changes at all -- no reciprocal marker, nothing added to it.
- **One-directional by default.** A `Depends-On:` line on the kdm-controller PR makes *that job* pull in the named kdm-plugin PR. It does not make the kdm-plugin job pull in the controller PR back -- that's a different job reading a different PR's description. For a symmetric combo (both jobs testing both PRs together), add a `Depends-On:` line to *both* PRs, each pointing at the other.
- **Editing it after the PR is already open works.** This step fetches the PR description live from the GitHub API every run, not a cached copy from PR-open time. Add/edit/remove the line, then `/test <job-name>` (or `/retest`, or push again) -- the very next run picks up whatever the description says at that moment.
- **A later push to the *depended-on* PR does not auto-retrigger anything.** Only the triggering PR's own presubmit re-run (a new commit, `/retest`, or `/test <job-name>`) re-resolves, using whatever the depended-on PR's HEAD is at that moment.

### Worked example: oadp-operator depending on oadp-non-admin

Say a CRD field is being added in lockstep across two repos: `migtools/oadp-non-admin` PR #456 adds the field to its CRD, and a companion `openshift/oadp-operator` PR #789 updates the DPA-to-CRD sync logic to read it. Neither PR alone is fully testable -- the operator PR's new sync code has nothing to read without the CRD's new field, and the CRD PR alone has no consumer.

To test them together: add to oadp-operator PR #789's description -- a full PR description might look like this:

> ## Summary
>
> Reads the new `spec.backupSpec.excludedResources` field on `NonAdminBackup` and
> forwards it to the generated DPA, so non-admin users can exclude resources from
> their own backups the same way cluster-admins already can.
>
> Needs the CRD's own new field, added in a companion oadp-non-admin PR.
>
> Depends-On: https://github.com/migtools/oadp-non-admin/pull/456
>
> ## Test plan
>
> - [ ] e2e (`oadp-operator`'s `e2e-test-aws`, this PR's Depends-On resolves
>       oadp-non-admin#456 automatically)

`oadp-operator`'s `e2e-test-aws` job then: builds oadp-operator PR #789 (as it always does, via ci-operator's own `OO_INDEX` dependency -- unrelated to Depends-On), notices the Depends-On line matches its `migtools/oadp-non-admin` candidate, builds oadp-non-admin PR #456's source as an image, and (via `oadp-apply-depends-on-images`) patches the Subscription so `RELATED_IMAGE_NON_ADMIN_CONTROLLER` points at that PR-built image instead of whatever the released bundle ships -- before `make test-e2e` runs. The oadp-non-admin PR #456 itself needs no changes -- the `Depends-On:` line can sit anywhere in the description (own paragraph, bullet, wherever reads naturally); the resolver only looks for the line, not its surrounding structure.

### Environment Variables

- `OO_INSTALL_NAMESPACE`
  - The namespace to build the depended-on image(s) into. Should match the namespace the operator under test is installed into.
- `DEPENDS_ON_CANDIDATES`
  - One line per `(repo, image)` pair this job is willing to resolve, `<org>/<name> <RELATED_IMAGE_ENV_VAR_NAME> [<dockerfile-path>]`. Plain text, not JSON -- this image has no guaranteed `jq` (same reasoning as `oadp-operator-sdk-bundle-image`). `<dockerfile-path>` is optional (defaults to `Dockerfile` at the repo root); set it when a repo's own ci-operator config builds with something else (`Dockerfile.ubi`, `Containerfile`, etc). The same repo may appear on more than one line -- a repo producing several images (e.g. `migtools/oadp-vm-file-restore`, which builds 3 separate `RELATED_IMAGE_*` targets from 3 different Dockerfiles) gets its source fetched once and built once per matching line. Add more lines to test more repos (or more images per repo) together in the same job; this script does not change.
  - The second field is normally a real `RELATED_IMAGE_*` env var name, but the sentinel value `MANAGER_IMAGE` is special-cased by consumers that install oadp-operator itself (the 4 KDM configs) -- it means "this candidate is oadp-operator's own manager image, not a component oadp-operator deploys," and gets applied by patching the manager Deployment's own container image directly (`oc set image`) instead of a Subscription env var. This resolver step itself treats `MANAGER_IMAGE` like any other value (just writes the line to the manifest); only the *apply* side (KDM's own `set-related-image`) knows what to do with it. Covers oadp-operator PRs that change reconcile logic (e.g. how it builds a managed Deployment's spec) -- an oadp-operator PR that changes RBAC/CSV/CRD manifests still needs the alternate-bundle mechanism described in Known limitations below.

### Output

For each resolved candidate, one line is appended to `${SHARED_DIR}/depends-on-images.txt`: `<RELATED_IMAGE_ENV_VAR_NAME> <pullspec>`. A downstream step (e.g. `oadp-apply-depends-on-images`, or KDM's inline `set-related-image` test step) reads this file and folds each line into its own patch. The file does not exist at all when nothing was resolved.

## Known limitations

- **Unauthenticated GitHub API calls**: same as `openstack-k8s-operators-kuttl-commands.sh`, no token is used, so this is subject to GitHub's unauthenticated rate limit (60/hr per IP). Acceptable for now given the existing precedent; would need a credentialed step if this becomes a bottleneck.
- **First real run still pending**: rehearsal only exercises the no-Depends-On (default) path, since no real PR carries the marker yet. The positive path needs a real pair of PRs to verify end-to-end -- one carrying a `Depends-On:` line, the other just existing as a normal open PR (no reciprocal marker needed, per the trigger semantics above) -- e.g. a KDM controller/plugin pair, or an oadp-operator PR against any one of its 17 sibling repos.
- **Always put `Depends-On:` on the oadp-operator PR, never the sibling's, for any scenario touching oadp-operator's own RBAC/CSV/CRD manifests.** `MANAGER_IMAGE` (above) covers reconcile-logic-level oadp-operator dependencies from a *sibling's* job (kdm-controller's own configs use it), but a change to oadp-operator's RBAC/CSV/CRDs themselves isn't a container-image swap at all -- it needs the operator's *own* bundle build, RBAC/CSV/CRDs and all, which only oadp-operator's own `e2e-test-aws` produces natively (via ci-operator's `OO_INDEX` dependency, entirely separate from this resolver). There is no gap here in practice: this resolver is already wired into oadp-operator's own job with `migtools/oadp-non-admin` as one of its candidates, so testing "an oadp-operator PR that changes RBAC together with a companion oadp-non-admin PR" is fully supported today -- just author/edit the **oadp-operator PR's** description with `Depends-On: https://github.com/migtools/oadp-non-admin/pull/<N>` (exactly the worked example above), not the other way around. A sibling repo's own e2e attempting to pull in an unmerged oadp-operator PR directly has no way to build that alternate bundle (see the worked example's own direction) -- don't attempt it from that side.

## Provenance

PR-description convention follows `ci-operator/step-registry/openstack-k8s-operators/kuttl/openstack-k8s-operators-kuttl-commands.sh`. Written for [openshift/oadp-operator#2389](https://github.com/openshift/oadp-operator/issues/2389), first wired into the KDM e2e jobs from [openshift/oadp-operator#1832](https://github.com/openshift/oadp-operator/issues/1832) / openshift/release#83049.
