# Release Gating Jobs.

This directory contains the configuration for release gating and informing jobs.  [Our documentation](https://docs.ci.openshift.org/docs/architecture/release-gating/) contains details on the future direction for nightly payload gating.  Please discuss with the [Technical Release Team approvers](/OWNERS_ALIASES) before working on any new blocking jobs.  Jobs marked as "optional: true" will be prioritized.

Our strategy for ensuring backport quality and assessing backports for merge is based on acceptance and pass rates in master.
Every backport is first merged into master, then passes automated testing, then can be backported.
This means that a new job must first become blocking on master before becoming blocking on release
branches in order to be confident that our backports will pass our release branch testing.
If an exception is required due to instability of a job on master, that exception must be accepted
by the party responsible for release branch quality, currently the rotation of patch managers.
