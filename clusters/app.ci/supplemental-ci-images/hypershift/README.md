# Special notes for building HyperShift images
* `hypershift-cli` image serves both as the CLI and the operator.
* Due to lack of forward/backward-compatibility of HyperShift, it is critical that we tag the build. For instance, once a new build of `BuildConfig/hypershift-cli` is complete, we shall manually make a tag for that image while `latest` could be moved forward:
```
oc --context app.ci -n ci tag hypershift-cli:latest hypershift-cli:20230428-12e6a502bd6a7ea5434df2b83fef102b7819b413 --as system:admin
```
The naming convention is `YYYYMMDD-<git commit hash>`.
* If an aarch64 build is needed, we shall ensure it is built form the SAME source code as amd64, on the SAME commit
