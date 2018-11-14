Openshift-ansible templates for master/4.x
=========

openshift-ansible repo for 4.0 has been reworked, it now requires a bootstrap ignition file and
has different inventory and group vars.

The CI flow has been updated to include latest installer image, which is used to generate bootstrap
ignition file first.
