# oadp-depends-on-build-ref<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->

- [Purpose](#purpose)
- [Process](#process)
  - [Trigger semantics for a multi-repo PR author](#trigger-semantics-for-a-multi-repo-pr-author)
  - [Environment Variables](#environment-variables)
  - [Output](#output)
- [Known limitations](#known-limitations)
- [Provenance](#provenance)

## Purpose

Lets a CI job testing one repo's PR also pull in an unmerged PR from one or more sibling repos, via a `Depends-On:` line in the triggering PR's own description -- the same PR-description convention already used by `openstack-k8s-operators-kuttl-commands.sh`. Unlike that step (a plain source checkout), a resolved dependency here becomes a real pushed container image, because downstream needs an actual pullspec (e.g. a Kubernetes `Subscription`'s `RELATED_IMAGE_*` override).

Written generically to cover the N-repo case tracked by [openshift/oadp-operator#2389](https://github.com/openshift/oadp-operator/issues/2389) ("test oadp-operator + kdm-controller + kdm-plugin + velero-plugin-for-aws etc. together"), but **currently only consumed by the 4 kubevirt-datamover-controller/-plugin (KDM) e2e configs** (`migtools/kubevirt-datamover-{controller,plugin}` × `oadp-dev`/`oadp-1.6`), each declaring exactly one candidate: its own sibling repo. See [openshift/oadp-operator#1832](https://github.com/openshift/oadp-operator/issues/1832) for the KDM e2e coverage this builds on.

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

### Environment Variables

- `OO_INSTALL_NAMESPACE`
  - The namespace to build the depended-on image(s) into. Should match the namespace the operator under test is installed into.
- `DEPENDS_ON_CANDIDATES`
  - One line per sibling repo this job is willing to resolve, `<org>/<name> <RELATED_IMAGE_ENV_VAR_NAME>`. Plain text, not JSON -- this image has no guaranteed `jq` (same reasoning as `oadp-operator-sdk-bundle-image`). Add more lines to test more repos together in the same job; this script does not change.

### Output

For each resolved candidate, one line is appended to `${SHARED_DIR}/depends-on-images.txt`: `<RELATED_IMAGE_ENV_VAR_NAME> <pullspec>`. A downstream step (e.g. this job's `set-related-image` test step) reads this file and folds each line into its own patch. The file does not exist at all when nothing was resolved.

## Known limitations

- **Unauthenticated GitHub API calls**: same as `openstack-k8s-operators-kuttl-commands.sh`, no token is used, so this is subject to GitHub's unauthenticated rate limit (60/hr per IP). Acceptable for now given the existing precedent; would need a credentialed step if this becomes a bottleneck.
- **No re-trigger on a later push to the depended-on PR**: this step resolves whatever the depended-on PR's HEAD is at the moment *this* job runs. A push to the sibling PR after this job started does not retrigger it -- the triggering PR's own presubmit re-run (any new push, or `/retest`) is what re-resolves.
- **First real run still pending**: rehearsal only exercises the no-Depends-On (default) path, since no real KDM PR carries the marker yet. The positive path needs a real paired kdm-controller/kdm-plugin PR pair to verify end-to-end.

## Provenance

PR-description convention follows `ci-operator/step-registry/openstack-k8s-operators/kuttl/openstack-k8s-operators-kuttl-commands.sh`. Written for [openshift/oadp-operator#2389](https://github.com/openshift/oadp-operator/issues/2389), first wired into the KDM e2e jobs from [openshift/oadp-operator#1832](https://github.com/openshift/oadp-operator/issues/1832) / openshift/release#83049.
