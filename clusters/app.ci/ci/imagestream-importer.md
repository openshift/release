# ImageStream Importer

Configuration supporting the [imagesteam importer job](https://prow.ci.openshift.org/?job=periodic-imagestream-importer).

Default imagestreams (like python) were not updating on the CI cluster. This job runs weekly to do an `oc import-image`.