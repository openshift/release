# CoreOS ART publication

The `publish-art` postsubmit builds both image dependencies in its own job
namespace. Its generated target is `publish-art`, not `[images]`: simply adding
a post step to another test would not execute it in the image-only promotion
job. The original images postsubmit continues reference-only CI promotion to
`origin/scos-5.1`. ART publication is independent and does not assume ordering
between these two postsubmits or read either one's floating promotion tags.

The step receives digest-qualified dependencies from ci-operator's
`envForDependencies` / `ImageDigestFor`. It rejects tag-only fallbacks. It mirrors
each dependency to a digest-named QCI tag with `--keep-manifest-list`, retaining
registry content independently of the temporary build namespace. The import
source is the QCI repository **at that same digest**, never the mirror tag.

The script has four phases: `validate_inputs`, `mirror_images`, `update_art_tags`,
and `wait_for_imports`. The blocks after mirroring are not just checks:
`update_art_tags` writes both ImageStream tag specs to enable controller imports.
Its response checks establish the assigned generations; `wait_for_imports`
then verifies those exact imports without accepting a superseding update.
The jq helper defines the two tag names as a JSON array directly in jq, rather
than requiring a shell variable containing JSON for `--argjson`.

Both ART tags are updated together using `oc replace` on the ImageStream,
preserving unrelated tags and supplying its resource version. `reference: false`,
`importPolicy.importMode: PreserveOriginal`, and `generation: 0` request a new
controller import without an `imagestreamimports` request from this job. The
existing promotion-quay-tagger account permits ImageStream get/update; no patch,
additional RBAC, or direct image-import permission is needed.

The response must retain the requested build digests and import policies before
its assigned spec generations are accepted. Polling requires the same
stream UID and exact target specs, a nonempty imported image equal to the build
digest, and matching status/spec generations for both tags in one snapshot.
Current-generation import failure conditions fail immediately; pending imports
time out after 60 polls with 5-second sleeps and 10-second API request timeouts.
Failures report allowlisted digests, generations and import-condition reasons,
not raw references, condition messages or client output. Only the explicit
server optimistic-update conflict diagnostic is retried, at most three attempts
and only while the original target specs remain unchanged. Other update errors
fail closed with their exit status and a safe error category. Their outcome is
unconfirmed: a client timeout may occur after the server commits the update, so
it is neither retried nor attributed to a superseding writer.
A superseding writer, even for the same digest with a newer generation, fails
the job rather than being credited or overwritten by a retry.

Credentials are explicit cluster-synced bundles mounted by the CI
credential consumer: `ci/promotion-quay-tagger-kubeconfig` and
`ci/registry-push-credentials-ci-central`. The latter already includes build13
source-registry pull and QCI push credentials, as used by normal promotion.
Only postsubmits may run this publisher; rehearsals are disabled.

These paths and dependency variables are not baked into the CLI image. The ref's
credential declarations mount the bundles at `/etc/app-ci-kubeconfig` and
`/etc/push-secret`; their expected keys are `kubeconfig` and `.dockerconfigjson`.
The script exports `KUBECONFIG` and sets its local `registry_config` variable to
those files, failing before any API or mirror operation if either is missing,
unreadable or empty. Its `sources` array is built from `STREAM_COREOS_IMAGE` and
`STREAM_COREOS_EXTENSIONS_IMAGE`, injected by ci-operator from the ref's image
dependencies, not from pre-existing CLI-image environment variables.

The write destination is `quay.io/openshift/ci`, matching normal ci-operator
promotion (`api.QuayOpenShiftCIRepo`). Import pull specs use
`quay-proxy.ci.openshift.org/openshift/ci` at the same immutable digest. The
proxy is not assumed to support writes. The publisher uses the same existing
credential bundles as normal promotion, but is a separate multi-stage pod;
source configuration does not prove identical node placement, pod service
account or runtime network reachability. Successful build13 registry access and
controller imports require runtime validation, not an inference from these URLs.
