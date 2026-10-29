## Repository-specific instructions (openshift/release)

This repository holds CI configuration. **This overrides the generic instruction
"Do not modify CI configuration or generated files"**: editing files under
`ci-operator/config/`, `ci-operator/step-registry/` and `core-services/` is the
purpose of this repository and is expected for most issues, including when
addressing review comments.

- Never edit files under `ci-operator/jobs/` or `zz_generated_metadata` by hand;
  regenerate them with `make update`.
- Read `CLAUDE.md` before making changes.
- Verify changes with `make update`, `make check-core` and `make ci-operator-checkconfig`.
- Commit the config changes together with the generated job files.
