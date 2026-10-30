# OSL release manifest

Prepare a manifest for each OSL release candidate. It configures the OSL RC
Prow job's RHDH/OCP combination and Logic catalog. Registry pull credentials
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

Copy the template to a working file, then replace every placeholder:

```bash
cd /home/rlan/redhat/release
MANIFEST=/tmp/osl-release.json
install -m 600 hack/osl-release/manifest.template.json "$MANIFEST"
${EDITOR:-vi} "$MANIFEST"
```

Confirm every required field has a value and the IIB image is digest-pinned:

```bash
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

Review the manifest with `jq . "$MANIFEST"`. Upload only after validation
succeeds and every placeholder has a real value.

The job always installs `serverless-operator` from the `stable` channel of
`redhat-operators`. OLM selects the latest available version at run time, so it
can change as the catalog updates. Do not add a `serverless` object. The job
rejects it.

## Upload and run the rehearsal

Update the `release-json` field in the `osl-rc` group of the
`rhdh-plugin-export-overlays` collection. The step mounts it at
`/var/run/vault/osl-rc/release.json`.

```bash
SM="$PWD/hack/secret-manager.sh"
"$SM" login
"$SM" list -c rhdh-plugin-export-overlays
"$SM" update \
  -c rhdh-plugin-export-overlays \
  osl-rc/release-json \
  --from-file "$MANIFEST"
```

If `osl-rc/release-json` does not exist, use `create`. Otherwise, use `update`.
The manifest contains release metadata, not registry passwords. Login requires a
working `gcloud` installation and access to the collection.

Secret updates do not enqueue a job. Trigger the rehearsal manually:

```bash
gh pr comment 85665 \
  --repo openshift/release \
  --body '/pj-rehearse pull-ci-redhat-developer-rhdh-plugin-export-overlays-main-e2e-ocp-helm-osl-rc'

gh pr checks 85665 --repo openshift/release --watch --interval 30
```

Accept the run when it reports 29 passed, 2 intentional skips, 0 unexpected, and 0
flaky tests. Confirm the artifacts include `playwright-report/results.json`.
