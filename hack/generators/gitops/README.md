# GitOps ApplicationSets

Source of truth: `applicationsets.yaml`. Output: `clusters/gitops/apps/appset-*.yaml`.

```bash
make gitops-applicationsets          # regenerate
./hack/validate-gitops-applicationsets.sh .   # presubmit check
```
