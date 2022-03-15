sippy-redirector
====

Deploys a reverse proxy on `app.ci` which redirects traffic from https://sippy.ci.openshift.org/ to https://sippy.dptools.openshift.org/

Sippy has moved to the dpcr cluster to be maintained by the TRT team. To keep DNS working so all existing links still function, DPTP suggested using a redirector service to point to the new deployment. (similar to rhcos-redirector)

