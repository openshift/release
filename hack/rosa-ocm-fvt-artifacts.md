# OCM FVT artifact publication

Run the offline delivered-step fixtures with:

```sh
python3 hack/test_rosa_ocm_fvt_artifacts.py
bash -n ci-operator/step-registry/rosa/e2e/ocm-fvt/rosa-e2e-ocm-fvt-commands.sh
shellcheck -S warning ci-operator/step-registry/rosa/e2e/ocm-fvt/rosa-e2e-ocm-fvt-commands.sh
```

The registry delivers only each ref's declared command body, not sibling files.
Every consuming job declares `rosa-e2e-ocm-fvt-prepare` immediately before
`rosa-e2e-ocm-fvt`. The prepare ref uses `run_as_script: true`: ci-operator mounts
its Python command from the workflow commands ConfigMap and executes its shebang.
That command copies its own source exclusively into
`${SHARED_DIR}/ocm-fvt-artifacts.py` with mode 0600. Shared-state transfer carries that
file to the FVT pod, whose Bash wrapper calls its staging, digest, metadata and
publication entry points. No repository checkout, image change or runtime fetch
is needed. A missing helper stops before FVT or credential handling begins.

The helper source is
`ci-operator/step-registry/rosa/e2e/ocm-fvt/prepare/rosa-e2e-ocm-fvt-prepare-commands.py`.
Its preparation entry point handles public source code only. The fixture copies
only the two declared command bodies, executes the prepare command from a
temporary mount, removes that mount, and runs the wrapper using the installed
helper. It mocks Podman, not the production filesystem publication code. Registry resolution,
shellcheck and generated registry metadata have separate repository CI checks;
the fixture is a standalone focused behavioral check.

Delivery follows ci-tools `pkg/load/load.go:loadReference` (one command body),
`pkg/steps/multi_stage/init.go:createCommandConfigMaps` (bodies keyed by step), and
`pkg/steps/multi_stage/gen.go:generatePods`/`addCommandScript` (mounted executable
for `run_as_script`). The entrypoint wrapper's `createSecret` serializes files
with `util.SecretFromDir` for the standard shared-state mechanism; the next pod
receives the helper bytes along with other workflow state. This is not a shared
host filesystem or repository mount, and does not depend on retaining an inode.

## Evidence and permission model

Public Prow run [2113533554481696768](https://prow.ci.openshift.org/view/gs/test-platform-results-public/logs/periodic-ci-openshift-online-rosa-e2e-main-ocm-fvt-rosa-classic-staging-ocm-fvt-periodic-cs-rosa-sts-pl-ocp5-latest-rc-staging-main/2113533554481696768)
records result directories with mode 2755, UID 1998 and GID 1000; report files are
0644 with the same ownership. The wrapper collector is UID 1000, GID 0, with
supplementary groups 0,1000. Group access permits reading and traversing results,
but not creating the `tmp-censor*` files that the public sidecar log reports as
permission denied. Changing report-file writability alone cannot fix this:
censoring also needs directory write and execute permissions to replace reports.

The public pod specification gives both wrapper and sidecar UID 1000 and mounts
the same `/logs` volume. The sidecar artifact upload source is `/logs/artifacts`.
Fresh directories 0700 and files 0600 owned by the wrapper therefore give the
sidecar access to read, create temporary files and rename over reports without
granting additional access to other users. Publication does not preserve producer
ownership or use hard links, chown, additional identities, or privileged helpers.

The same-UID regression uses a source directory 0555 and report 0444, observes a
real temporary-file creation denial, then creates and atomically replaces a report
in the published directory. It verifies that the source contents, modes and inode
are unchanged. This is not a multi-UID test: the observed production identities
and POSIX permission analysis supplement the executable regression.

## Producer isolation and consumer coverage

Before running the producer, the wrapper reserves a private temporary directory
beside `ARTIFACT_DIR`, verifies that its parent and staging are on the artifact
filesystem, and rejects symlinked artifact paths. Failure stops before FVT starts
with a generic error; raw results are never redirected back into the upload tree.
The private parent has no group/other access (inherited setgid is harmless).
The existing producer output directory permissions remain unchanged. Podman's
bind mount exposes that output directory directly at the unchanged container
path `/ocm-backend-tests/output`; the producer does not need traversal access to
the host-side private parent. No nested-user privilege or mapping change is needed.

All existing raw-output consumers retain `ocm_fvt_output` and run before
publication:

| Consumer | Preserved behavior |
| --- | --- |
| Artifact permission metadata | Observes original producer modes/ownership, not copied modes |
| Merged JUnit report | Copies `report.xml` to the existing top-level JUnit artifact |
| Cluster ID and guest kubeconfig | Reads original `cluster.ini`/kubeconfigs; retains shared-state handling |
| Gather eligibility | Retains readiness checks, guest API check and stale-kubeconfig removal |
| Deferred cleanup | Persists original `.datainfo` and profile paths to the existing shared and artifact tarballs; archive member paths are unchanged |
| Final artifact publication | Copies regular report/diagnostic files only after these consumers finish |

Top-level digest, metadata, JUnit, job-name, eligibility and deferred-clean archive
artifacts remain in their existing locations. No changes are made to cleanup,
cluster lifecycle, credential handling or test output verbosity.

## Publication safety and completeness

Publication recreates the output tree with collector-owned directories 0700 and
files 0600, including phase and merged XML/JSON, test-matrix JSON and HTML, logs,
text, images, archives and other regular diagnostics without an extension allowlist.
Known private state (`.datainfo`, `cluster.ini`, `kubeconfig`, `*.kubeconfig`) is
excluded from this browsing tree; its existing shared-state/deferred-clean consumers
run first and are unchanged. Symlinks and special files are excluded, not followed.
Unreadable entries and rejected non-regular entries produce a generic warning;
neither their names nor their contents are logged.

Source traversal uses descriptor-relative no-follow opens and checks opened file
types. Limits are 8192 entries, depth 16 and 256 MiB of copied content per step.
Exceeding a limit fails the whole publication with a generic warning rather than
silently publishing a truncated diagnostic tree. A completed private copy is
renamed into the artifact tree; partial copies and raw originals stay outside
collection. Existing publication destinations are not overwritten.

The raw originals and unsuccessful copies remain private until pod teardown;
recursively removing foreign-owned result directories would require permissions
the collector does not have. Publication failure never bypasses censoring and
never replaces the original FVT exit status. This repairs artifact censorability,
not the original unknown provisioning failure.
