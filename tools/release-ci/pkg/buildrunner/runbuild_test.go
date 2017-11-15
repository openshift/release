package buildrunner

import (
	"io/ioutil"
	"os"
	"testing"
)

func TestExtractBuildName(t *testing.T) {
	tests := []struct {
		name       string
		content    string
		expectErr  bool
		expectName string
	}{
		{
			name:       "build yaml",
			expectName: "simple-build-1",
			content: `apiVersion: v1
kind: Build
metadata:
  annotations:
    openshift.io/build-config.name: release-ci-binary
    openshift.io/build.number: "1"
    openshift.io/build.pod-name: release-ci-binary-1-build
  name: simple-build-1
spec:
  output:
    pushSecret:
      name: builder-dockercfg-wp4q5
    to:
      kind: ImageStreamTag
      name: release-ci:binary
  postCommit: {}
  resources: {}
  serviceAccount: builder
  source:
    contextDir: tools/build/release-ci-binaries-image
    git:
      ref: master
      uri: https://github.com/openshift/release.git
    type: Git
  strategy:
    dockerStrategy:
      from:
        kind: ImageStreamTag
        name: release:test
      noCache: true
    type: Docker
status:
  phase: Complete
`,
		},
		{
			name:       "build json",
			expectName: "jenkins-secrets-controller-1",
			content: `
{
    "apiVersion": "v1",
    "kind": "Build",
    "metadata": {
        "annotations": {
            "openshift.io/build-config.name": "jenkins-secrets-controller",
            "openshift.io/build.number": "1",
            "openshift.io/build.pod-name": "jenkins-secrets-controller-1-build"
        },
        "name": "jenkins-secrets-controller-1",
    },
    "spec": {
        "output": {
            "pushSecret": {
                "name": "builder-dockercfg-wp4q5"
            },
            "to": {
                "kind": "ImageStreamTag",
                "name": "jenkins-secrets-controller:latest"
            }
        },
        "postCommit": {},
        "resources": {},
        "serviceAccount": "builder",
        "source": {
            "contextDir": "jenkins/controllers/secrets",
            "git": {
                "ref": "master",
                "uri": "https://github.com/openshift/release.git"
            },
            "type": "Git"
        },
        "strategy": {
            "dockerStrategy": {
                "from": {
                    "kind": "DockerImage",
                    "name": "openshift/origin:latest"
                }
            },
            "type": "Docker"
        },
        "triggeredBy": [
            {
                "message": "Build configuration change"
            }
        ]
    },
    "status": { 
	}
}`,
		},
		{
			name:      "pod",
			expectErr: true,
			content: `apiVersion: v1
kind: Pod
metadata:
  labels:
    app: jenkins-secrets-controller
  name: jenkins-secrets-controller-1-n8crg
spec:
  containers:
  - env:
    - name: JENKINS_TEMPLATE_NAME
      value: jenkins-persistent
    image: jenkins-secrets-controller@sha256:2fcc70650a4098feaa8419cb99d05fcbfae6912fac58e1c28bce455e9dbeb4d6
    imagePullPolicy: Always
    name: jenkins-secrets-controller
    resources: {}
    terminationMessagePath: /dev/termination-log
    terminationMessagePolicy: File
    volumeMounts:
    - mountPath: /var/run/secrets/kubernetes.io/serviceaccount
      name: jenkins-admin-token-wqs6k
      readOnly: true
  dnsPolicy: ClusterFirst
  imagePullSecrets:
  - name: jenkins-admin-dockercfg-lw2mt
  nodeName: origin-ci-ig-n-kwtq
  nodeSelector:
    role: app
  restartPolicy: Always
  schedulerName: default-scheduler
  serviceAccountName: jenkins-admin
  terminationGracePeriodSeconds: 30
  volumes:
  - name: admin-token-wqs6k
    secret:
      defaultMode: 420
      secretName: admin-token-wqs6k
status: { }`,
		},
	}

	for _, test := range tests {
		tmp, err := ioutil.TempFile("", "")
		if err != nil {
			t.Fatalf("%s: unexpected: %v", test.name, err)
		}
		tmp.Close()
		defer os.Remove(tmp.Name())
		err = ioutil.WriteFile(tmp.Name(), []byte(test.content), 0644)
		if err != nil {
			t.Fatalf("%s: unexpected: %v", test.name, err)
		}
		buildName, err := extractBuildName(tmp.Name())
		if err != nil {
			if !test.expectErr {
				t.Errorf("%s: unexpected error: %v", test.name, err)
			}
			continue
		}
		if err == nil && test.expectErr {
			t.Errorf("%s: expected error, but got none", test.name)
			continue
		}
		if buildName != test.expectName {
			t.Errorf("%s: expected: %s, actual: %s", test.name, test.expectName, buildName)
		}
	}
}
