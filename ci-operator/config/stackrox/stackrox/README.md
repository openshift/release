# StackRox OpenShift CI configs

https://prow.ci.openshift.org/?repo=stackrox%2Fstackrox

When creating Pull Requests, mind [Making Changes to OpenShift
CI](https://docs.engineering.redhat.com/display/StackRox/Making+changes+to+OpenShift+CI)
and `Pull Request checklist` therein.

### Release Template

`stackrox-stackrox-release-x.y*.template` files are template YAML used by
automation to create config for release at branch time. 

*When changes are made to master or nightlies yaml consider if the changes are
also appropriate for release branches.*
