# On-demand agentic-ci pin maintenance

Run the checker on a POSIX host from a public `openshift/release` checkout
with Python 3.9+, PyYAML, and packaging. Use the upstream remote for these
commands.

```bash
python3 -m venv venv
source venv/bin/activate
python3 -m pip install PyYAML 'packaging>=21'
git fetch origin main
hack/check-agentic-ci-version.py
```

The checker resolves `refs/remotes/origin/main` once (`--ref` selects another
local ref or SHA). It reads the three `agentic-dev` definitions for Sippy,
Origin, and SHIP Status Dashboard from that commit. The recognized install is
the standalone `RUN python3 -m pip install --no-cache-dir agentic-ci==VERSION`
in the final stage of each inline Dockerfile. Changed Dockerfile command shapes
or missing, ambiguous, or diverged pins require review.

The JSON report contains the commit, config paths, blob IDs, pins, PyPI metadata
digest, candidate, and reason. `no_change` and `update_available` exit zero.
`blocked` exits 2. `newer_series` shows the newest published version seen per
later series for human review, including previews when they are the newest
published version. A generated patch is available only with
`--prepare-patch VERSION` and the matching `update_available` result. The
checker sends its output to stdout.

## Evaluate a candidate

The checker reads bounded [public PyPI metadata][pypi], orders releases using
PEP 440, and considers newer final `0.5.x` patches with non-yanked files.
It needs a non-yanked `py3-none-any` wheel with a declared `Requires-Python`
matching the exact interpreter versions for all three images. It reports any
higher patch skipped for a lack of a matching wheel. Source distributions,
platform-specific wheels, and wheels without a Python requirement cannot
establish compatibility in v1. This verifies distribution metadata. Dependency
resolution, installation, and startup still need the checks below.

The public base Dockerfiles use Fedora and distro packages. Each release config
reads a mutable devcontainer tag. The source files establish the interpreter
install path, while the exact Python version depends on the image build.
Record the full `python3 --version` and immutable digest/image ID from each
actual `agentic-dev` build for the source commit. Inspect the builds in a
credential-free container with networking disabled and the entrypoint overridden
to `python3`. Review the provenance of each observation before supplying
`--image-evidence`. The checker verifies the evidence structure and commit
association using these operator-supplied observations.

```json
{
  "source_commit": "<full resolved release commit>",
  "images": {
    "sippy": {"image_digest": "sha256:<64 hex digits>", "python": "<major.minor.patch>"},
    "origin": {"image_digest": "sha256:<64 hex digits>", "python": "<major.minor.patch>"},
    "ship-status-dash": {"image_digest": "sha256:<64 hex digits>", "python": "<major.minor.patch>"}
  }
}
```

Public source for the three bases. [Sippy][sippy] · [Origin][origin] ·
[SHIP Status Dashboard][ship]

## Prepare and review one grouped bump

After reviewing the result, fetch upstream `main` again. Use a clean worktree
at that exact commit, fresh interpreter evidence for that snapshot, and the
reviewed candidate. The preparation call re-reads the pins and public PyPI.
If the recommendation or input commit has changed, review the new evidence
before continuing. Keep the report, evidence, and patch outside the worktree.

```bash
set -e
git fetch origin main
source_commit=$(git rev-parse refs/remotes/origin/main)
test "$(git rev-parse HEAD)" = "$source_commit"
test -z "$(git status --porcelain)"
hack/check-agentic-ci-version.py --ref "$source_commit" \
  --image-evidence "$evidence" --prepare-patch "$reviewed_version" > "$report"
jq -er 'select(.status == "update_available") | .patch' "$report" > "$patch"
git apply --check "$patch"
git apply "$patch"
git diff --check
git diff
```

1. Verify that the diff changes exactly the three pin values and review the
   candidate release notes. Run `make update` and `make checkconfig` per
   [repository guidance][guidance]. Review the full diff again and investigate
   any generated or unrelated change before proceeding.
2. Build each of the three patched `agentic-dev` image definitions with the
   exact candidate in an approved build-only environment without promotion.
   Use each config's devcontainer, helper, nested-podman and source inputs.
   Record the inputs and result image IDs. In every result, verify
   `importlib.metadata.version("agentic-ci")` equals the reviewed candidate,
   using `python3` with the image entrypoint overridden.
3. Require an isolated CLI import smoke for all three built images before opening
   the bump PR. Use a clean, unprivileged runtime with networking disabled, no
   credentials or host mounts, and the image's normal entrypoint bypassed.
   The public `0.5.15` wheel exposes `agentic-ci = agentic_ci.cli:main`.
   Check the candidate's entry point and run the import with the exact local
   result image ID. This check ends before CLI dispatch or solver startup.
   `EVAL_MODE` can still publish. Keep solver and follow-up workflows out of this
   procedure.

   ```bash
   podman run --rm --pull=never --network=none --read-only --cap-drop=ALL \
     --security-opt=no-new-privileges --entrypoint=python3 "$image_id" -I -c \
     'from agentic_ci.cli import main; assert callable(main)'
   ```

4. Recheck upstream pins and PyPI before opening the PR. Open one grouped,
   human-reviewed PR for the three values and include the source commit,
   candidate, generation checks, build/version results, and CLI import evidence.
   Check for an existing PR for the same bump and continue review there if it
   exists. Leave maintainer-closed bumps closed and keep auto-merge disabled.

[pypi]: https://pypi.org/pypi/agentic-ci/json
[sippy]: https://github.com/openshift/sippy/blob/c6228a446f7920bf636f2eb1196ddad0fe1937e0/.devcontainer/Dockerfile
[origin]: https://github.com/openshift/origin/blob/06fc55ab6c540bb95e62530d4ef65314320847d9/.devcontainer/Dockerfile
[ship]: https://github.com/openshift-eng/ship-status-dash/blob/600e4b53a2e5a9f28f897479fc063cb82030dcc6/.devcontainer/Dockerfile
[guidance]: ../AGENTS.md#modifying-ci-for-a-repository
