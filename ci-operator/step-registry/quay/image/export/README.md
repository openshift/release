# Quay image export

Export one ci-operator image to an explicitly tagged Quay repository using `oc
image mirror`. This is a reusable step, not a runnable Prow job, release payload
builder, or generic builder for arbitrary pull requests. No component configuration
or credentials are installed by this directory.

## Interface

- `QUAY_EXPORT_SOURCE`: dependency pullspec, injected by ci-operator. The base ref
  uses `src`; callers should bind the desired image using test-level `dependencies`.
- `QUAY_EXPORT_DESTINATION`: required `quay.io/organization/repository:tag`.
  Only this registry and a single repository/tag are accepted; URLs, credentials,
  digests, transport prefixes, and additional destinations are rejected.
- `QUAY_EXPORT_AUTH_FILE`: path to caller-mounted Docker auth JSON, default
  `/var/run/quay-export/config.json`, with an `auths["quay.io"].auth` entry.
  Supply the JSON itself, not a base64 encoding of the entire JSON file.
- `ARTIFACT_DIR`: supplied by ci-operator. On success, `quay-image-export.json`
  records the destination, observed SHA-256 digest, and digest pullspec.

The step obtains build-registry authentication with `oc registry login`, running
only that login with `KUBECONFIG` unset in a subshell so an inherited test-cluster
context does not select its credentials. The caller's environment is preserved for
subsequent operations, which use the explicit merged registry config. The merge
retains source auth entries and adds only the caller's `quay.io` entry. It does not
copy unrelated destination credentials into the merged config. Auth and inspection
files stay in a private temporary directory, removed on exit (including errors,
SIGINT and SIGTERM). As with any process, SIGKILL cannot run cleanup; pod teardown
must dispose of its ephemeral filesystem. Secret contents and raw registry-command
output are not logged or placed in artifacts or `SHARED_DIR`. Mirror and inspection
failures fail the step. Manifest lists are preserved. The artifact describes what
the destination tag resolves to at inspection time; concurrent writers can move
the tag, so use a unique tag per build and consume the digest pullspec.

## Caller wiring and GSM credentials

ci-operator does **not** merge `credentials` into a `ref` at the call site. A
`TestStep` must be either a reference or a literal step, not both. Workflow/test
environment and dependency overrides work, but credentials remain literal fields
of the referenced step. Do not write `ref: quay-image-export` next to `credentials`,
or put credential selection into Gangway environment overrides.

Instead, create a caller-owned registry ref with the actual credential selection,
sharing this script through a command-file symlink. This is the same registry
loader path used by existing symlinked command files. The base ref intentionally
has no secret reference; using it alone does not mount Quay credentials.

For example, in `ci-operator/step-registry/example/quay-export/`, create
`example-quay-export-commands.sh` as a symlink:

```sh
ln -s ../../quay/image/export/quay-image-export-commands.sh \
  ci-operator/step-registry/example/quay-export/example-quay-export-commands.sh
```

Use this `example-quay-export-ref.yaml` template. **Replace all angle-bracket
placeholders** with approved values before installing it. No real collection,
group, field, or Quay repository is assumed here. Keep the wrapper's image, env,
dependency and resource definitions aligned with the base ref when upgrading it.
Add the required `OWNERS` files and run the registry generators and validation.

```yaml
ref:
  as: example-quay-export
  from_image:
    namespace: ocp
    name: cli-jq
    tag: latest
  commands: example-quay-export-commands.sh
  credentials:
  - collection: <gsm-collection>
    group: <gsm-group>
    field: <gsm-field>
    as: config.json
    mount_path: /var/run/quay-export
  dependencies:
  - env: QUAY_EXPORT_SOURCE
    name: src
  env:
  - name: QUAY_EXPORT_DESTINATION
    documentation: Explicit tagged destination in the approved Quay repository.
  - name: QUAY_EXPORT_AUTH_FILE
    default: /var/run/quay-export/config.json
  resources:
    requests:
      cpu: 100m
      memory: 200Mi
  timeout: 1h
  grace_period: 30s
  documentation: Export a caller-selected image with caller-owned credentials.
```

Include the wrapper in the test phase of an existing multi-stage workflow/test.
This fragment belongs inside an existing component ci-operator configuration;
`images` must already define `my-image`, with the component's own Dockerfile and
build inputs. This is not a standalone job configuration:

```yaml
tests:
- as: export-image
  steps:
    dependencies:
      QUAY_EXPORT_SOURCE: pipeline:my-image
    env:
      QUAY_EXPORT_DESTINATION: quay.io/<organization>/<repository>:<unique-tag>
    test:
    - ref: example-quay-export
```

The resolver replaces the dependency's `name` by matching its `env`, so
`pipeline:my-image` makes that image build before this step in the **same
ci-operator invocation**. It does not trigger or wait for a separate `images`
ProwJob. Add the ref to a configured workflow/test before expecting any export.

After configuring and generating an actual presubmit, trigger that existing job
using normal CI commands or the documented Gangway REST API. A registry ref cannot
be independently triggered by Gangway. Runtime destination selection is supported
through `QUAY_EXPORT_DESTINATION`; how a job supplies it depends on its configured
environment. Gangway overrides do not rewrite credential collection/group/field
literals. This change neither triggers a job nor configures API credentials.

## Deployment security

Use a least-privilege Quay robot limited to write access on the intended export
repository, not an organization administrator. Protect trusted/release tags from
untrusted presubmit outputs. Anyone able to run modified PR code with mounted
credentials may be able to steal or misuse them; CI log censoring and this script's
cleanup are not a sandbox for hostile code. Review job trust/authorization and
credential exposure policies before enabling exports for PRs. The destination
parameter is not an authorization boundary: enforce repository access with the
robot's permissions. There is no live Quay validation in the offline tests.

## Validation and public references

```sh
bash hack/test-quay-image-export.sh
shellcheck ci-operator/step-registry/quay/image/export/quay-image-export-commands.sh hack/test-quay-image-export.sh
make registry-metadata
make ci-operator-checkconfig
```

- [GSM secret onboarding](https://docs.ci.openshift.org/how-tos/adding-a-new-secret-to-ci-gsm/)
- [Triggering ProwJobs via REST](https://docs.ci.openshift.org/how-tos/triggering-prowjobs-via-rest/)
- [Step API (`TestStep`, `LiteralTestStep`, `CredentialReference`)](https://github.com/openshift/ci-tools/blob/main/pkg/api/types.go)
- [Resolver (`process`, `resolveStep`, dependency overrides)](https://github.com/openshift/ci-tools/blob/main/pkg/registry/resolver.go)
- [Registry command-file loading](https://github.com/openshift/ci-tools/blob/main/pkg/load/load.go)
- [GSM credential resolution](https://github.com/openshift/ci-tools/blob/main/pkg/steps/multi_stage/init.go)
