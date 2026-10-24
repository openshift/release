# OSL release manifest

Use this guide for each OSL release candidate. The manifest tells the OSL RC
Prow job which RHDH/OCP combination and Logic operator catalog to test. It is
release configuration; registry pull credentials are supplied separately by
the `openshift-qe/mirror-registry` CI secret.

## 1. Gather the values

- `rhdhVersion`: the RHDH version under test.
- `ocpVersion`: the minor version claimed by the Prow job's `cluster_claim`.
  The current job is configured for `4.20`. If the release targets another OCP
  minor, update `cluster_claim.version` and regenerate the Prow jobs before
  triggering the rehearsal.
- `logic.iib`: select the IIB image for that OCP version from the OSL email,
  then resolve its tag to a digest.
- `logic.package`, `logic.channel`, and `logic.startingCSV`: read these from
  the selected IIB catalog's Logic package metadata.
- `logic.expectedVersion`: use the selected CSV's `.spec.version`; do not
  derive it from the email's release label, which may include a suffix such as
  `.CR3`.

Resolve the digest for the OCP-specific catalog tag from the email:

```bash
IIB_TAG='registry-proxy.engineering.redhat.com/rh-osbs/iib:<ocp-specific-tag>'
IIB_DIGEST=$(skopeo inspect --no-creds --no-tags \
  --format '{{.Digest}}' "docker://${IIB_TAG}")
LOGIC_IIB="registry-proxy.engineering.redhat.com/rh-osbs/iib@${IIB_DIGEST}"
printf '%s\n' "$LOGIC_IIB"
```

`--no-creds` requests anonymous access. If the registry rejects that request,
authenticate to `registry-proxy.engineering.redhat.com` with an account allowed
to read the image; Quay credentials do not authenticate to this registry.

Extract the catalog files for inspection without installing the operator:

```bash
CATALOG_DIR=$(mktemp -d)
oc image extract "$LOGIC_IIB" \
  --path="/configs/logic-operator/:${CATALOG_DIR}/catalog" \
  --only-files
```

Inspect the extracted `catalog.json` and verify the Logic package, channel,
CSV name, and that CSV's `.spec.version`. Use the catalog values for this
candidate; do not assume they match the version label in the email.

## 2. Fill and validate the manifest

Copy the template to a working file and replace every angle-bracketed value:

```bash
cd /home/rlan/redhat/release
MANIFEST=/tmp/osl-release.json
install -m 600 hack/osl-release/manifest.template.json "$MANIFEST"
${EDITOR:-vi} "$MANIFEST"
```

Validate that all required fields are populated and the IIB image is
digest-pinned:

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

Review the final values with `jq . "$MANIFEST"`. The template is not ready to
upload until all placeholders have been replaced and validation succeeds.

The job always installs `serverless-operator` from the `stable` channel of
`redhat-operators`. OLM selects the latest version available in that channel
when the job runs, so the Serverless version can change as the catalog is
updated. Do not add a `serverless` object to the manifest; the job rejects it
instead of silently ignoring stale Serverless settings.

## 3. Upload it for Prow

The OSL RC step expects Secret Manager collection `rhdh-plugin-export-overlays`,
group `osl-rc`, field `release-json`; the step reference maps it to
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

Use `create` instead of `update` only when `osl-rc/release-json` does not
already exist. The manifest contains release metadata, not registry passwords.
The login requires a working `gcloud` installation and access to the collection.
After updating the secret, trigger the Prow rehearsal manually; changing the
secret does not enqueue a job by itself:

```bash
gh pr comment 85665 \
  --repo openshift/release \
  --body '/pj-rehearse pull-ci-redhat-developer-rhdh-plugin-export-overlays-main-e2e-ocp-helm-osl-rc'

gh pr checks 85665 --repo openshift/release --watch --interval 30
```

Accept the run when it reports 29 passed, 2 intentional skips, 0 unexpected,
and 0 flaky tests, and its artifacts contain
`playwright-report/results.json`.
