# Jobs

The jobs in this directory automate verifying the integration of OCP nightly releases and stable releases.

## Streams

Here, we test with `nightly` and `stable` stream of images from OpenShift.

## Naming

ci-operator config in this directory should be named with the following patterns:

* `openshift-verification-tests-master__<stream>-<release_number>.yaml` - Contains all jobs that share the same integration stream
* `openshift-verification-tests-master__<stream>-<release_number>-upgrade-from-<stream>-<release_number>.yaml` - Contains upgrade jobs from stream to stream

Variables:

* `<stream>` may be one of:
   * `nightly`: A release generated from the published ART nightly release stream
   * `stable`: A published public OCP release (which are renamed `nightly` builds) such as `4.6.10`
* `<release_number>` must be of the form `4.<number>`, i.e. `4.10`

Examples:

* `openshift-verification-tests-master__nightly-4.10.yaml` contains verification tests for releases built from ART
* `openshift-verification-tests-master__nightly-4.10-upgrade-from-stable-4.9.yaml` tests upgrading to a nightly 4.10 release from the current stable 4.9 release

## Interval

Different test interval are used for different OCP versions.

* For the latest version under heavy development/test, set interval to 24h for common jobs.
* For the latest version under heavy development/test, set interval to 168h for destructive jobs.
* For the other versions, set interval to 72h for common jobs.
* For the other versions, set interval to 168h for destructive jobs.

Specially, for installer rehearse jobs, set interval to 960h.
