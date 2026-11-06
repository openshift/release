# Optional AWS PR release selection

`/test e2e-from-pr-aws` requests one optional, non-gating main PR job. It uses
the normal nested AWS v2 management cluster and PR-built operator/test image.
Only the guest and test release inputs change. Existing jobs are unchanged.
The retained `arm64` build-farm capability matches the existing AWS v2 job;
guest payloads and node pools in this workflow are **amd64 only**.

Add this exact section to the PR body (not its title):

```markdown
## Release Test Matrix
### AWS
- [ ] release-4.21
- [X] release-4.20
- [ ] release-4.19
```

This selects 4.20. Lowercase `[x]` also works. Only the first checked item in
document order is used; later checked entries are logged as ignored, not fanned
out into more jobs. Other platform subsections, other sections and fenced code
examples are excluded. Missing selection, duplicate/ambiguous headings and
malformed checked entries fail explicitly. Currently only canonical `4.X`
minors, AWS and linux/amd64 are supported; there is no silent default/fallback.

The resolver fetches the public PR once successfully, with bounded retries for
transient/rate-limit failures. It checks repository, number, head SHA and base
`main`. No GitHub secret is needed; public API quotas/egress still apply.
Requests use fixed HTTPS hosts, no redirects, bounded response size/time and
no PR-derived URLs. The API body is never printed or retained as an artifact.
This is an **execution-time metadata snapshot**: a matching head SHA does not
freeze an editable body. A new execution reads again, including a Deck copy;
an infrastructure retry of the resolver can also read newer same-SHA metadata.

The amd64 release controller supplies the latest Accepted `<minor>.0-0.ci`
payload. Its `/latest` endpoint filters Accepted releases and sorts semantic
versions. The resolver independently validates phase/name, and selects the
highest numeric GA z-version in the same minor from `4-stable/tags`, excluding
RC/prereleases and non-Accepted entries. It never falls back to nightly or a
different minor. `oc image info` verifies linux/amd64 and resolves the digest;
`oc adm release info` verifies the version of that immutable payload.

The resolver atomically writes three validated, shell-safe digest exports to
`${SHARED_DIR}/nodepool_release_images`:

- `RELEASE_IMAGE_LATEST`: selected Accepted CI payload.
- `OCP_IMAGE_N1`: selected same-minor GA stable payload, including upgrade guests.
- `E2E_PREVIOUS_RELEASE_IMAGE`: the same GA stable payload (not a previous minor).

The existing create-guests hook sources this file unchanged. The copied test
chain validates its complete format before sourcing it, overriding named-image
dependency defaults immediately before `run-tests` (which maps latest into
`E2E_LATEST_RELEASE_IMAGE`). Shell exports in a previous pod are not relied on.
The normal nodepool resolver is omitted because it truncates this file.
Management payload/CLI, PR-built HyperShift operator, preparation, credentials,
timeouts, exit status and post cleanup retain the existing AWS v2 paths.
CPO selection is unchanged: absent an explicit override, it uses the guest
payload's `hypershift` component, not necessarily a PR-built CPO. This workflow
does not introduce a CPO override or claim PR CPO coverage for stock payloads.
Minimal `pr-release-matrix.json` artifacts record selected minor/platform,
head SHA, fetch time and resolved names/pullspecs/digests; no full body/headers.

Run the offline fixtures, using Python 3 and the repository's PyYAML dependency:

```sh
python3 hack/test_hypershift_pr_releases.py -v
shellcheck -S warning ci-operator/step-registry/hypershift/resolve-pr-releases/*-commands.sh
```

Fixtures stub public HTTP and image commands, run the actual resolver and
create/test shell consumers (substituting only the application binary), and
assert existing source/generated jobs remain identical. They do not provision
AWS resources. Repository generators/registry validators must also be run;
these local tests are not an end-to-end CI/cloud rehearsal.
