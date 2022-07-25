rpm flow
===========

rpms are built using `rpm_build_commands` and committed into image named `rpms` which gets promoted as image `oc-rpms`. We merge rpms from `oc-rpms` image into `artifacts` in origin during its build (https://github.com/openshift/release/blob/8c66c42a2a3b63afdf795b7d29f94a4ff0c466af/ci-operator/config/openshift/origin/openshift-origin-master.yaml#L72-L75). Currently it implies that updating oc rpms CI repo requires waiting for a merge into origin. Test platform team should provide tooling for triggering that dependent build automatically after we promote a new `oc-rpms` image.

rpms are served at https://artifacts-rpms-openshift-origin-ci-rpms.apps.ci.l2s4.p1.openshiftapps.com 
