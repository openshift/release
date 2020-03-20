# Guard the base images from being GCed

The `dont-gc-me-bro` daemonset guards the base images from being
garbage-collected on nodes, preventing the ci-operator workloads from failing
with the following errors:

```
error: build error: no such image
```
