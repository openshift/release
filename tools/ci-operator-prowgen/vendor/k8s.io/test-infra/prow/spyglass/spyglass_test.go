/*
Copyright 2018 The Kubernetes Authors.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package spyglass

import (
	"fmt"
	"os"
	"testing"

	"github.com/fsouza/fake-gcs-server/fakestorage"
	"github.com/sirupsen/logrus"
	"k8s.io/test-infra/prow/config"
	"k8s.io/test-infra/prow/deck/jobs"
	"k8s.io/test-infra/prow/kube"
	"k8s.io/test-infra/prow/spyglass/viewers"
)

var (
	fakeJa        *jobs.JobAgent
	fakeGCSServer *fakestorage.Server
)

const (
	testSrc = "gs://test-bucket/logs/example-ci-run/403"
)

type fkc []kube.ProwJob

func (f fkc) GetLog(pod string) ([]byte, error) {
	return nil, nil
}

func (f fkc) ListPods(selector string) ([]kube.Pod, error) {
	return nil, nil
}

func (f fkc) ListProwJobs(s string) ([]kube.ProwJob, error) {
	return f, nil
}

type fpkc string

func (f fpkc) GetLog(pod string) ([]byte, error) {
	if pod == "wowowow" || pod == "powowow" {
		return []byte(f), nil
	}
	return nil, fmt.Errorf("pod not found: %s", pod)
}

func (f fpkc) GetContainerLog(pod, container string) ([]byte, error) {
	if pod == "wowowow" || pod == "powowow" {
		return []byte(f), nil
	}
	return nil, fmt.Errorf("pod not found: %s", pod)
}

func (f fpkc) GetLogTail(pod, container string, n int64) ([]byte, error) {
	if pod == "wowowow" || pod == "powowow" {
		tailBytes := []byte(f)
		lenTailBytes := int64(len(tailBytes))
		if lenTailBytes < n {
			return tailBytes, nil
		}
		return tailBytes[lenTailBytes-n-1:], nil
	}
	return nil, fmt.Errorf("pod not found: %s", pod)
}

func TestMain(m *testing.M) {
	var longLog string
	for i := 0; i < 300; i++ {
		longLog += "here a log\nthere a log\neverywhere a log log\n"
	}
	fakeGCSServer = fakestorage.NewServer([]fakestorage.Object{
		{
			BucketName: "test-bucket",
			Name:       "logs/example-ci-run/403/build-log.txt",
			Content:    []byte("Oh wow\nlogs\nthis is\ncrazy"),
		},
		{
			BucketName: "test-bucket",
			Name:       "logs/example-ci-run/403/long-log.txt",
			Content:    []byte(longLog),
		},
		{
			BucketName: "test-bucket",
			Name:       "logs/example-ci-run/403/junit_01.xml",
			Content: []byte(`<testsuite tests="1017" failures="1017" time="0.016981535">
<testcase name="BeforeSuite" classname="Kubernetes e2e suite" time="0.006343795">
<failure type="Failure">
test/e2e/e2e.go:137 BeforeSuite on Node 1 failed test/e2e/e2e.go:137
</failure>
</testcase>
</testsuite>`),
		},
		{
			BucketName: "test-bucket",
			Name:       "logs/example-ci-run/403/started.json",
			Content: []byte(`{
						  "node": "gke-prow-default-pool-3c8994a8-qfhg", 
						  "repo-version": "v1.12.0-alpha.0.985+e6f64d0a79243c", 
						  "timestamp": 1528742858, 
						  "repos": {
						    "k8s.io/kubernetes": "master", 
						    "k8s.io/release": "master"
						  }, 
						  "version": "v1.12.0-alpha.0.985+e6f64d0a79243c", 
						  "metadata": {
						    "pod": "cbc53d8e-6da7-11e8-a4ff-0a580a6c0269"
						  }
						}`),
		},
		{
			BucketName: "test-bucket",
			Name:       "logs/example-ci-run/403/finished.json",
			Content: []byte(`{
						  "timestamp": 1528742943, 
						  "version": "v1.12.0-alpha.0.985+e6f64d0a79243c", 
						  "result": "SUCCESS", 
						  "passed": true, 
						  "job-version": "v1.12.0-alpha.0.985+e6f64d0a79243c", 
						  "metadata": {
						    "repo": "k8s.io/kubernetes", 
						    "repos": {
						      "k8s.io/kubernetes": "master", 
						      "k8s.io/release": "master"
						    }, 
						    "infra-commit": "260081852", 
						    "pod": "cbc53d8e-6da7-11e8-a4ff-0a580a6c0269", 
						    "repo-commit": "e6f64d0a79243c834babda494151fc5d66582240"
						  },
						},`),
		},
	})
	defer fakeGCSServer.Stop()
	kc := fkc{
		kube.ProwJob{
			Spec: kube.ProwJobSpec{
				Agent: kube.KubernetesAgent,
				Job:   "job",
			},
			Status: kube.ProwJobStatus{
				PodName: "wowowow",
				BuildID: "123",
			},
		},
		kube.ProwJob{
			Spec: kube.ProwJobSpec{
				Agent:   kube.KubernetesAgent,
				Job:     "jib",
				Cluster: "trusted",
			},
			Status: kube.ProwJobStatus{
				PodName: "powowow",
				BuildID: "123",
			},
		},
	}
	fakeJa = jobs.NewJobAgent(kc, map[string]jobs.PodLogClient{kube.DefaultClusterAlias: fpkc("clusterA"), "trusted": fpkc("clusterB")}, &config.Agent{})
	fakeJa.Start()
	os.Exit(m.Run())
}

func dumpViewHandler(artifacts []viewers.Artifact, raw string) string {
	var view []byte
	for _, a := range artifacts {
		data, err := a.ReadAll()
		if err != nil {
			logrus.WithError(err).Error("Error reading artifact")
			continue
		}
		view = append(view, data...)
	}
	return string(view)
}

func TestViews(t *testing.T) {
	fakeGCSClient := fakeGCSServer.Client()
	testAf := NewGCSArtifactFetcher(fakeGCSClient)
	testCases := []struct {
		name               string
		registeredViewers  map[string]viewers.ViewMetadata
		fetchers           []ArtifactFetcher
		matchCache         map[string][]string
		expectedLensTitles []string
	}{
		{
			name: "Spyglass basic test",
			registeredViewers: map[string]viewers.ViewMetadata{
				"metadata-viewer": {
					Title:    "MetadataView",
					Priority: 0,
				},
			},
			fetchers: []ArtifactFetcher{testAf},
			matchCache: map[string][]string{
				"metadata-viewer": {"started.json"},
			},
			expectedLensTitles: []string{"MetadataView"},
		},
		{
			name:     "Spyglass no matches",
			fetchers: []ArtifactFetcher{testAf},
			registeredViewers: map[string]viewers.ViewMetadata{
				"metadata-viewer": {
					Title:    "MetadataView",
					Priority: 0,
				},
			},
			matchCache: map[string][]string{
				"metadata-viewer": {},
			},
		},
	}
	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			for k, v := range tc.registeredViewers {
				viewers.RegisterViewer(k, v, dumpViewHandler)
			}
			sg := New(fakeJa, tc.fetchers)
			lenses := sg.Views(tc.matchCache)
			for _, l := range lenses {
				var found bool
				for _, title := range tc.expectedLensTitles {
					if title == l.Title {
						found = true
					}
				}
				if !found {
					t.Errorf("lens title %s not found in expected titles.", l.Title)
				}
			}
			for _, title := range tc.expectedLensTitles {
				var found bool
				for _, l := range lenses {
					if title == l.Title {
						found = true
					}
				}
				if !found {
					t.Errorf("expected title %s not found in produced lenses.", title)
				}
			}
		})
	}
}
