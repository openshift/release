# Build ci tools written in Go

The template in this directory builds an image that contains the release-ci binary tool. It also 
creates a jenkins slave image that contains the binary.

To build using the command-line:

```
oc new-app -f https://raw.githubusercontent.com/openshift/release/master/tools/build/build-tools.yaml
```

Optional template parameters are:
- RELEASE_URL - git URL of the source repository to build from
- RELEASE_REF - git ref of the source repository to build from

For example, to build from one of your branches:
```
oc new-app -f https://raw.githubusercontent.com/openshift/release/master/tools/build/build-tools.yaml \
  -p RELEASE_URL=https://github.com/yourname/release.git -p RELEASE_REF=your_branch
```

To install using the web console:
1. Create a new project
2. Click on 'Add to Project'
3. Click on 'Import YAML/JSON'
4. Paste the contents of the `build-tools.yaml` from this directory into the text area.
5. Click on 'Create'