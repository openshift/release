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

Credentials are explicit cluster-synced bundles mounted read-only by the CI
credential consumer: `ci/promotion-quay-tagger-kubeconfig` and
`ci/registry-push-credentials-ci-central`. The latter already includes build13
source-registry pull and QCI push credentials, as used by normal promotion.
Only postsubmits may run this publisher; rehearsals are disabled.

Run the offline contract tests without cluster access:

```sh
python3 hack/scos-art-publish/test_publish_art.py
```
