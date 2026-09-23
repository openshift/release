sippy-redirector
====

Deploys an nginx to 301 redirect traffic from https://sippy.ci.openshift.org/ to https://sippy.dptools.openshift.org/

Sippy has moved to the dpcr cluster to be maintained by the TRT team. To
keep DNS working so all existing links still function, DPTP suggested
using a redirector service to point to the new deployment.
