**This feature is not fully deployed to production yet**

At the moment, all `openshift/release` pull requests trigger a
`ci/prow/pj-rehearse` presubmit that is running the rehearse tool in the
following way:

1. dry mode: it never actually submits rehearsal jobs to Prow
2. no-fail mode: the job should never fail, even if it should fail in
   production
3. optional: if the job fails despite the no-fail mode, it does not block a
   merge

The reason for running the tool in this "stealth" mode is that we can monitor
its behavior until we finalize remaining rough edges. The timeframe for
production deployment is mid-February 2019.

# CI job rehearsals

Pull requests to this repository that contain changes affecting Prow job setup
trigger a so-called "rehearsal". Jobs that would be affected by a PR are
executed as if run against a target component repository after job changes
would be merged. This provides job config authors early feedback about how job
config changes impact CI setup for a given repo.

## How rehearsal works

All pull requests trigger a `ci/prow/pj-rehearse` check, which detects the jobs
affected by the proposed change. For each job selected for rehearsal (for
various reasons, we are not able to rehearse all jobs), new Prowjob is
dynamically created, reporting results via a GitHub context named with the
`ci/rehearse/$org/$repo/$test` pattern.

## Which jobs are rehearsed

At the moment, we are not able to rehearse all affected jobs for various
reasons. Currently, we only rehearse `Presubmit` jobs affected by the
following changes:

1. Newly added presubmit jobs
2. Presubmit jobs whose `spec:` field was changed
3. Presubmit jobs whose `agent:` field was changed to `kubernetes` from a
   different value

These jobs are then further filtered to exclude jobs where some factor prevents
us from reliably rehearsing them. Decisions about why a job was excluded from
rehearsing are logged in the output of the `ci/prow/pj-rehearse` job. Most
importantly, we are currently *not* rehearsing template-based jobs.

## Future work
In the near future, we would like to enlarge the set of jobs that are
rehearsed. First, changes to several fields other that `spec:` should cause a
rehearsal. Afterwards, we would like to enable rehearsing template-based jobs.
Additionally, we want to consider for rehearsal even jobs that are affected by
a change *indirectly*, e.g., by a change of an underlying ci-operator config
file, template or other asset used by the job.
