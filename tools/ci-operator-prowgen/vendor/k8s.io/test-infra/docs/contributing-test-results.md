# Contributing Test Results

The Kubernetes project welcomes contributions of test results from organizations
that execute e2e test jobs.  This ensures we have coverage of Kubernetes on more
platforms than just those that the Kubernetes project itself can fund or support.

The process is as follows:

- Designate a point of contact (github handle / e-mail / github team) that we can
  reach out to if needed (eg: mitigating flood/drought of data, assisting with
  migrations, etc)
- Create a GCS bucket that is [world-readable](https://cloud.google.com/storage/docs/access-control/making-data-public)
- Run e2e tests (we recommend using [kubetest](/kubetest/README.md))
- Store test results in accordance with [Gubernator's GCS Layout](/gubernator/README.md#gcs-layout)
  - Unfortunately this part is currently left as an exercise to the reader. We use
    [bootstrap](/jenkins/bootstrap.py) to facilitate this and are in the midst of
    rewriting it to better support external usage.
- Add the GCS bucket info to [buckets.yaml](/kettle/buckets.yaml) via a PR (use the
  previously designated github handle for the `contact` field).
- Add jobs and dashboards to the [testgrid config](/testgrid/config.yaml) via
  a PR (use the previously designated point of contact info in a comment next to
  added `test_group`s, or even better in the `description` field for added
  `dashboard_tab`s)

As of this writing, a good example GCS bucket to grep for in this repo would be the
`k8s-conformance-openstack` bucket.

We are actively working on improving this process, which means that this
document may not be kept exactly up-to-date. Feel free to file an issue against
this repo when you run into problems.

We prefer test results that are actively kept up to date and maintained. This is
especially true for testgrid, where stale dashboards clutter up the UI. We may
periodically identify GCS buckets, jobs, or testgrid dashboards that have become
more than 90 days stale and remove them via revertible PR.
