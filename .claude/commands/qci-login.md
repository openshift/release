---
name: qci-login
description: Help login to QCI (quay.io/openshift/ci) image registry for pulling images
parameters:
  - name: action
    description: Action to perform - "login", "verify", "pull", or "help" (default: help)
    required: false
  - name: image_ref
    description: Optional image reference to pull after login (e.g., "ci/ci-operator:latest")
    required: false
---
You are helping users login to QCI (quay.io/openshift/ci) image registry.

## Context

QCI (quay.io/openshift/ci) is the authoritative CI registry for OpenShift CI images. Access requires:
- Authentication through `quay-proxy.ci.openshift.org` reverse proxy
- OpenShift SSO token from `app.ci` cluster
- RBAC permissions (Rover group in `qci-image-puller` rolebinding)

## Your Task

Based on the user's request: action="{{action}}"{{#if image_ref}}, image="{{image_ref}}"{{/if}}

1. **Provide guidance** based on the action:

   **login** - Help login to QCI:
   - Authentication setup
   - Login commands
   - Token retrieval
   - Verification steps

   **verify** - Verify QCI access:
   - Test authentication
   - Check permissions
   - Verify image access

   **pull** - Pull image from QCI:
   - Convert image reference format
   - Pull command with authentication
   - Platform-specific pulls

   **help** - General help:
   - QCI overview
   - Access requirements
   - Common use cases

2. **Prerequisites**:

   - Access to `app.ci` cluster
   - RBAC permissions (Rover group in `qci-image-puller` rolebinding)
   - `oc` CLI configured with `app.ci` context
   - `podman` or `docker` installed

3. **Login Process**:

   **Step 1: Get OpenShift Token**:
   ```bash
   # If app.ci context is configured
   oc whoami -t
   
   # Or login to app.ci first
   oc login https://api.ci.l2s4.p1.openshiftapps.com:6443
   oc whoami -t
   ```

   **Step 2: Login to QCI**:
   ```bash
   # Using podman
   podman login -u=$(oc --context app.ci whoami) \
     -p=$(oc --context app.ci whoami -t) \
     quay-proxy.ci.openshift.org \
     --authfile /tmp/qci-auth.json
   
   # Using docker
   echo $(oc --context app.ci whoami -t) | docker login \
     -u $(oc --context app.ci whoami) \
     --password-stdin \
     quay-proxy.ci.openshift.org
   ```

   **Step 3: Verify Login**:
   ```bash
   # Test with podman
   podman pull quay-proxy.ci.openshift.org/openshift/ci:ci_ci-operator_latest \
     --authfile /tmp/qci-auth.json \
     --platform linux/amd64
   
   # Test with docker
   docker pull quay-proxy.ci.openshift.org/openshift/ci:ci_ci-operator_latest
   ```

4. **Image Reference Conversion**:

   Convert ci-operator config format to QCI format:
   - Config format: `ci/ci-operator:latest`
   - QCI format: `quay.io/openshift/ci:ci_ci-operator_latest`
   - Authenticated format: `quay-proxy.ci.openshift.org/openshift/ci:ci_ci-operator_latest`

   Pattern: `<namespace>/<name>:<tag>` → `quay.io/openshift/ci:<namespace>_<name>_<tag>`

5. **Common Issues**:

   **Access Denied**:
   - Check if Rover group is in `qci-image-puller` rolebinding
   - Verify group is configured for `app.ci` cluster
   - File PR to add group if missing

   **Authentication Failed**:
   - Ensure `oc` is logged into `app.ci` cluster
   - Check token is valid: `oc whoami -t`
   - Verify context: `oc config current-context`

   **Image Not Found**:
   - Verify image exists in QCI (check quay.io/openshift/ci)
   - Check image reference format is correct
   - Ensure namespace/name/tag are correct

6. **Access Setup** (if not already configured):

   **For Human Users**:
   - File PR to `clusters/app.ci/assets/admin_qci-image-puller_rbac.yaml`
   - Add Rover group as subject in `qci-image-puller` rolebinding
   - Group must be configured for `app.ci` cluster in Rover config

   **For ServiceAccounts (Automation)**:
   - Create ServiceAccount in `clusters/app.ci/registry-access/` directory
   - Include RBAC configuration
   - Use ServiceAccount token for authentication

## Example Output

**Login to QCI**:
```bash
# Get token
oc whoami -t

# Login with podman
podman login -u=$(oc --context app.ci whoami) \
  -p=$(oc --context app.ci whoami -t) \
  quay-proxy.ci.openshift.org \
  --authfile /tmp/qci-auth.json

# Verify
podman pull quay-proxy.ci.openshift.org/openshift/ci:ci_ci-operator_latest \
  --authfile /tmp/qci-auth.json --platform linux/amd64
```

**Pull Image**:
```
Image: ci/ci-operator:latest
QCI Path: quay.io/openshift/ci:ci_ci-operator_latest
Pull: quay-proxy.ci.openshift.org/openshift/ci:ci_ci-operator_latest
```

Now help the user with: "{{action}}"{{#if image_ref}} for image "{{image_ref}}"{{/if}}

