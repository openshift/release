# Setup of Jenkins for CI

The template in this directory should be used to setup Jenkins for OpenShift CI

To install using the command-line:

```
oc new-app -f https://raw.githubusercontent.com/openshift/release/master/jenkins/setup/jenkins-setup-template.yaml
```

To install using the web console:
1. Create a new project
2. Click on 'Add to Project'
3. Click on 'Import YAML/JSON'
4. Paste the contents of the `jenkins-setup-template.yaml` from this directory into the text area.
5. Click on 'Create'
