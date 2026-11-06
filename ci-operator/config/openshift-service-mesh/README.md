# OSSM Service Mesh automation

`supported-istio-versions.txt` lists the supported upstream Istio minor versions,
one `major.minor` version per line, with no comments or blank lines.

When a new minor version becomes supported, add it and remove the version that
has dropped out of support. The weekday Istio z-stream release-branch job reads
this file from the default branch of `openshift/release` and processes only the
latest stable patch tag for each listed version.
