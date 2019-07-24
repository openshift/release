# Image Pruner

Configuration supporting the [image pruning job](https://prow.svc.ci.openshift.org/?job=periodic-ci-image-pruner).

The CI is building a huge number of images in its jobs, we need to prune them so
they do not end up taking space. See more about image pruning in OKD [docs](https://docs.okd.io/latest/admin_guide/pruning_resources.html#pruning-images).
