# Ship a shared, pre-built test-runner image for the OSC CI testsuites

**Summary:** Ship a shared, pre-built test-runner image for the OSC CI testsuites
instead of installing tools at runtime.

**Component / area:** Sandboxed Containers Operator CI (openshift/release
step-registry — `sandboxed-containers-operator/testsuites/*`)

---

## Problem

The OSC testsuites step family (starting with
`sandboxed-containers-operator-testsuites-kata-upstream`, with more runners
planned) executes upstream/downstream test runners that depend on tools not
present in the base CI image: `bats`, `yq`, `jq`, `envsubst` (plus `git`/`oc`).

The current step runs on `from: upi-installer` (provides `git`, `curl`, `oc` via
`cli: latest`) and installs the remaining tools **on-demand at runtime**,
downloading pinned versions from GitHub and verifying each against a recorded
SHA-256 (bats is git-cloned at a pinned tag and its commit SHA is verified).

This works and is safe against tampering, but has drawbacks:

- **Runtime network dependency / flakiness:** every job run downloads 3+
  binaries and clones bats from github.com; any outage or rate-limit fails the
  test.
- **Wasted time per run:** downloads repeat on every execution and for every
  runner step.
- **Maintenance drift:** pinned versions + SHAs live inside the step's
  `-commands.sh`; each new runner that needs the same tools risks
  re-implementing this.
- **Not the repo convention:** other custom test-runner images in
  openshift/release (`fuse-online-test-runner`, `windows-machine-config-operator-test`,
  `springboot-runner`) are pre-built as images and consumed via `from:`, not
  assembled at runtime.

As we add more runners (kata-downstream, etc.) they will all want the same
toolset — a **shared runner image** is the right primitive.

---

## Constraints (current state)

- The 8 `openshift-sandboxed-containers-operator-devel__downstream-*` configs
  that consume these steps **build no images, promote nothing, and have no
  `build_root`** — they install OSC from a released catalog.
- Only the `devel` main and `osc-release` configs build images (operator +
  bundle); **neither promotes** to a shared namespace. OSC currently publishes
  no shared image.

---

## Possible solutions

### Option A — `dockerfile_literal`, shared image built per config (lowest cost)

Add an `images:` entry building `sandboxed-containers-operator-testsuites-runner`
(base image + pinned/verified bats, yq, jq, envsubst) to each of the 8 downstream
configs; change the runner steps to
`from: sandboxed-containers-operator-testsuites-runner`. All runner steps in a
config reuse the one image. No `build_root`, no promotion, no operator-repo
change. Cost: the Dockerfile block is duplicated across the 8 near-identical
config files.

### Option B — `dockerfile_path` to a Dockerfile in openshift/sandboxed-containers-operator

Single Dockerfile as source of truth, but the build context is the `src` image,
so all 8 catalog-install configs must add `build_root` and build the operator
repo they currently don't build. Invasive; adds build time. Not recommended.

### Option C — build + promote once, consume via `base_images` (true cross-repo shared image)

Build `sandboxed-containers-operator-testsuites-runner` in one config and
`promotion:` it to a namespace; every consumer lists it in `base_images` and
does `from:`. One build, one source of truth, scales across configs and repos.
Most infrastructure to stand up (OSC promotes nothing today) and introduces a
build-before-consume ordering dependency. Natural long-term end state.

---

## Recommendation

Start with **A** (removes runtime downloads immediately, matches the "shared
image" goal with zero build/promotion changes); graduate to **C** if/when the
runner image needs to be shared beyond these configs. Also rename the image/step
family to a generic `sandboxed-containers-operator-testsuites-runner` since the
image is shared while each runner step stays suite-specific.

**Current behavior to preserve during migration:** enable-gate
(`TEST_<SUITE>_ENABLE`), skipped-JUnit-when-disabled, JUnit copied to
`${ARTIFACT_DIR}` for prow indexing, and `best_effort: true` non-blocking post
steps.
