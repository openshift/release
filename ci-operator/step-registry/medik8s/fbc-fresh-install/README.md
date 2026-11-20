# RHWA FBC fresh-install tests

Runs `tier:fresh-install` from `openshift/rhwa-system-tests` against a candidate
discovered from (or provided via) an RHWA FBC catalog.

## Flow

1. Discover or accept a digest-pinned FBC catalog (`FBC_CATALOG_MODE`).
2. Read the channel-head bundle image, version, and controller digests.
3. Prefer a public Quay mirror for the bundle when IDMS maps the source.
4. Export `NHC_UPGRADE_CANDIDATE_*` (or SBR equivalents) plus `*_OPERATOR_SDK`.
5. Apply the release `ImageDigestMirrorSet`.
6. Check out `SYSTEM_TESTS_REF` and `make run-tests` with `ECO_TEST_LABELS=tier:fresh-install`.

## Operators

`FBC_OPERATOR=nhc` is the supported path for s390x OZ jobs. `sbr` is accepted by
the step for future AWS/s390x wiring. NHC may discover an SNR GA peer bundle when
`NHC_UPGRADE_CANDIDATE_SNR_*` is unset.

## Runner image

Jobs must provide `fbc-fresh-install-test-runner` with Go, yq, skopeo, jq, and
`operator-sdk` at `/usr/local/bin/operator-sdk`.
