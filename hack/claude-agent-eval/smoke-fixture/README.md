# Temporary manifest workflow smoke test

This fixture exercises `openshift-claude-agent-eval-manifest` through its actual
workflow and ref in a rehearsal of the release PR. It is temporary test wiring,
not a production eval suite or a consumer migration.

The evals, cases, and minimal `code-review` plugin are copied from
[ai-helpers at da76969](https://github.com/openshift-eng/ai-helpers/tree/da76969fe72f0bd8b560383a93d48fa96dc15815).
Only the plugin paths in the eval configs are adjusted. The upstream Apache-2.0
license is included in this directory.

The root `evals.yaml` selects two passing evals when this fixture or the manifest
changes. Both intentionally use the same config basename, eval name, case ID,
and output filename to exercise per-eval artifact isolation. Their inputs and
expected classifications differ:

| Eval directory | Expected severity | Expected topic |
| --- | --- | --- |
| `manifest-smoke` | `nitpick` | `style` |
| `manifest-smoke-secondary` | `required_change` | `logic_bug` |

## CI wiring

`openshift-release-main__manifest-smoke-workflow.yaml` defines an optional,
manually triggered test. CI creates the release PR checkout in its normal `src`
image, then copies that checkout, including `.git`, into a job-local image based
on the existing Claude runtime. The checkout is writable by the OpenShift root
group; Git trusts only that checkout path. The workflow runs at `/workspace`
using Prow's release PR base SHA, without a cross-repository base override.
The image is declared under `images.items` so ci-operator recognizes
`from: claude-ai-helpers` as a build dependency in the `pipeline` image stream.
Declaring this build only in `raw_steps` does not establish that dependency:
the unqualified image name would instead resolve to the `stable` image stream.
The generated standalone images job is optional and skips automatic runs;
the smoke test still builds the image as its own dependency. The image is not
promoted. The Prow job timeout is 30 minutes; the unchanged ref
has its own 4-hour timeout, so the overall job limit bounds the run first.

After this commit is pushed, request the rehearsal on the release PR:

```text
/pj-rehearse pull-ci-openshift-release-main-manifest-smoke-workflow-eval-manifest-smoke
```

This command is documentation only; adding this fixture does not request a run.

## Acceptance and cleanup

Confirm that the candidate workflow resolves to the candidate ref and commands,
both evals actually run and pass, aggregate JUnit reports two tests and zero
failures, and each eval has its own complete artifact bundle. Check the uploaded
index links, archive contents, and metrics as well as the Prow result. A green
job with no selected evals does not satisfy this test.

Save the tested revision, resolved configuration, commands hash, build URL, and
artifact evidence before removing the root manifest, this entire fixture
directory, and the temporary CI config. Regenerate Prow jobs with the official
tools when removing the config. Keep the shared runner, workflow, and ref.
