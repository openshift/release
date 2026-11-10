# Stolostron Workflows

## Sync OWNERS in workflow metadata

Run this command:

```bash
owners_file=ci-operator/step-registry/ocm/OWNERS
owners=$(yq '.approvers' -I=0 -o=json "${owners_file}")

find "$(basename "${owners_file}")" -type f -name "*.metadata.json" \
  -exec yq -i -o json '.owners.approvers = '"${owners}" {} \;
```
