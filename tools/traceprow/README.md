## traceprow

Pass a link from a PR or PR comment and profit.

```console
traceprow https://github.com/openshift/origin/pull/17713#issuecomment-350767624
```

Bearer token auth is supported in case an Openshift oauth proxy sits in front of the tracer.

```console
traceprow --token=$(oc whoami -t) https://github.com/openshift/origin/pull/17713
```
