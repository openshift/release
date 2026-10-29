rpm flow
===========

rpms are built using `rpm_build_commands` and committed into image named `rpms` from which we take rpm artifacts and merge them with rpm artifacts from latest promoted `oc-rpms` image for a release coming from oc repository. Resulting image is called `artifacts` and served using https://github.com/openshift/release/tree/bfd9283068ce79631bab4e4ba3a679cff1b76eba/core-services/ci-rpms

rpms are served at https://artifacts-rpms-openshift-origin-ci-rpms.apps.ci.l2s4.p1.openshiftapps.com 
