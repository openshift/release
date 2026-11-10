# OSL release manifest

Prepare a manifest for each OSL release candidate. It configures the OSL RC
step's RHDH/OCP combination and Logic catalog. Registry pull credentials
come from the separate `openshift-qe/mirror-registry` CI secret.

## Select the Logic catalog

- `rhdhVersion`: RHDH version under test.
- `ocpVersion`: OCP minor in the Prow job's `cluster_claim`, currently `4.20`.
  If the release targets another OCP minor, update `cluster_claim.version`
  and regenerate the Prow jobs.
- `logic.iib`: IIB image for the target OCP version from the OSL email.
  Resolve its tag to a digest.
- `logic.package`, `logic.channel`, and `logic.startingCSV`: values from the
  selected IIB catalog.
- `logic.expectedVersion`: selected CSV's `.spec.version`, not the email's
  release label (which may include a suffix such as `.CR3`).

Resolve the OCP-specific catalog tag from the email:

```bash
IIB_TAG='registry-proxy.engineering.redhat.com/rh-osbs/iib:<ocp-specific-tag>'
IIB_DIGEST=$(skopeo inspect --no-creds --no-tags \
  --format '{{.Digest}}' "docker://${IIB_TAG}")
LOGIC_IIB="registry-proxy.engineering.redhat.com/rh-osbs/iib@${IIB_DIGEST}"
printf '%s\n' "$LOGIC_IIB"
```

`--no-creds` requests anonymous access. If the registry rejects that request,
authenticate to `registry-proxy.engineering.redhat.com` with an account that can
read the image.
Quay credentials do not work with this registry.

Extract the catalog without installing the operator:

```bash
CATALOG_DIR=$(mktemp -d)
oc image extract "$LOGIC_IIB" \
  --path="/configs/logic-operator/:${CATALOG_DIR}/catalog" \
  --only-files
```

Inspect `catalog.json` to confirm the Logic package, channel, CSV name, and
`.spec.version`. Use the values in the selected catalog.

## Create and validate the manifest

Create a working file from this template, then replace every placeholder:

```json
{
  "rhdhVersion": "<rhdh-version>",
  "ocpVersion": "<ocp-minor-version>",
  "logic": {
    "iib": "registry-proxy.engineering.redhat.com/rh-osbs/iib@sha256:<64-character-digest>",
    "package": "<logic-package-from-catalog>",
    "channel": "<logic-channel-from-catalog>",
    "startingCSV": "<logic-csv-from-catalog>",
    "expectedVersion": "<logic-version-from-csv-spec>"
  }
}
```

Save it as `/tmp/osl-release.json`. Confirm every required field has a value
and the IIB image is digest-pinned:

```bash
MANIFEST=/tmp/osl-release.json
jq -e '
  type == "object" and
  (.rhdhVersion | strings | length > 0) and
  (.ocpVersion | strings | length > 0) and
  (.logic.iib | strings | test("@sha256:[0-9a-f]{64}$")) and
  (.logic.package | strings | length > 0) and
  (.logic.channel | strings | length > 0) and
  (.logic.startingCSV | strings | length > 0) and
  (.logic.expectedVersion | strings | length > 0)
' "$MANIFEST"
```

Review the manifest with `jq . "$MANIFEST"`. Replace every placeholder before
using it. The job accepts only these seven fields. The Logic IIB must use a
digest-pinned `registry-proxy.engineering.redhat.com/rh-osbs/iib` image, and the
starting CSV must belong to the selected Logic package.

The job always installs `serverless-operator` from the `stable` channel of
`redhat-operators`. OLM selects the latest available version at run time, so it
can change as the catalog updates. Do not add a `serverless` object. The job
rejects it.

## Pass the manifest through Gangway

The Helm nightly periodic runs the ordinary overlays E2E suite unless Gangway
sets `MULTISTAGE_PARAM_OVERRIDE_OSL_MODE` to `rc`. An RC run also requires
`MULTISTAGE_PARAM_OVERRIDE_OSL_RELEASE_JSON` and
`MULTISTAGE_PARAM_OVERRIDE_OVERLAYS_SHA` in `pod_spec_options.envs`. Pass the
complete manifest as one JSON string and the overlays branch commit as a
40-character SHA. These overrides contain no credentials. Brew and stage
credentials remain in the separate `openshift-qe/mirror-registry` mount.

See the [Gangway REST API guide](https://docs.ci.openshift.org/how-tos/triggering-prowjobs-via-rest/)
for authentication and `pod_spec_options.envs`. The configured branches are
`main` and `release-2.1`; trigger the matching periodic
(`job_execution_type: "1"`):

| Branch | Gangway job |
| --- | --- |
| `main` | `periodic-ci-redhat-developer-rhdh-plugin-export-overlays-main-e2e-ocp-helm-nightly` |
| `release-2.1` | `periodic-ci-redhat-developer-rhdh-plugin-export-overlays-release-2.1-e2e-ocp-helm-nightly` |

Scheduled runs keep the ordinary nightly test. An RC run needs no pull request.
Future branches need the RC test added to their nightly ci-operator config.

Create the request with the current overlays `main` SHA and the manifest:

```bash
OVERLAYS_BRANCH=main # or release-2.1
OVERLAYS_SHA=$(git ls-remote https://github.com/redhat-developer/rhdh-plugin-export-overlays.git "refs/heads/${OVERLAYS_BRANCH}" | cut -f1)
[[ "$OVERLAYS_SHA" =~ ^[0-9a-f]{40}$ ]]
jq -n --arg branch "$OVERLAYS_BRANCH" --arg overlays_sha "$OVERLAYS_SHA" --rawfile release_json "$MANIFEST" '{
  job_name: ("periodic-ci-redhat-developer-rhdh-plugin-export-overlays-" + $branch + "-e2e-ocp-helm-nightly"),
  job_execution_type: "1",
  pod_spec_options: {envs: {
    MULTISTAGE_PARAM_OVERRIDE_OSL_MODE: "rc",
    MULTISTAGE_PARAM_OVERRIDE_OSL_RELEASE_JSON: $release_json,
    MULTISTAGE_PARAM_OVERRIDE_OVERLAYS_SHA: $overlays_sha
  }}
}' > /tmp/osl-rc-gangway.json
```

Submit `/tmp/osl-rc-gangway.json` using the authenticated REST request in the
Gangway guide.

Accept the run when it reports 29 passed, 2 intentional skips, 0 unexpected, and 0
flaky tests. The periodic's existing data-router and gather post steps also run.
