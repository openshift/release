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
	"testing"
)

func TestNewGCSJobSource(t *testing.T) {
	testCases := []struct {
		name        string
		src         string
		exJobPrefix string
		exBucket    string
		exName      string
		exBuildID   string
		expectedErr error
	}{
		{
			name:        "Test standard GCS link",
			src:         "gs://test-bucket/logs/example-ci-run/403",
			exBucket:    "test-bucket",
			exJobPrefix: "logs/example-ci-rin/403",
			exName:      "example-ci-run",
			exBuildID:   "403",
			expectedErr: nil,
		},
		{
			name:        "Test GCS link with trailing /",
			src:         "gs://test-bucket/logs/example-ci-run/403/",
			exBucket:    "test-bucket",
			exJobPrefix: "logs/example-ci-rin/403",
			exName:      "example-ci-run",
			exBuildID:   "403",
			expectedErr: nil,
		},
		{
			name:        "Test GCS link with org name",
			src:         "gs://test-bucket/logs/sig-flexing/example-ci-run/403",
			exBucket:    "test-bucket",
			exJobPrefix: "logs/example-ci-rin/403",
			exName:      "example-ci-run",
			exBuildID:   "403",
			expectedErr: nil,
		},
		{
			name:        "Test invalid GCS link",
			src:         "garbage/test-bucket/logs/sig-flexing/example-ci-run/403",
			expectedErr: ErrCannotParseSource,
		},
	}
	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			jobSource, err := newGCSJobSource(tc.src)
			if err != nil && err != tc.expectedErr {
				t.Errorf("Expected err: %v, got err: %v", err, tc.expectedErr)
			}
			if tc.exBucket != jobSource.bucket {
				t.Errorf("Expected bucket %s, got %s", tc.exBucket, jobSource.bucket)
			}
			if tc.exName != jobSource.jobName {
				t.Errorf("Expected name %s, got %s", tc.exName, jobSource.jobName)
			}
			if tc.exName != jobSource.jobName {
				t.Errorf("Expected name %s, got %s", tc.exName, jobSource.jobName)
			}
		})
	}
}

// Tests listing objects associated with the current job in GCS
func TestArtifacts_ListGCS(t *testing.T) {
	fakeGCSClient := fakeGCSServer.Client()
	testAf := NewGCSArtifactFetcher(fakeGCSClient)
	testCases := []struct {
		name              string
		handle            artifactHandle
		source            string
		expectedArtifacts []string
	}{
		{
			name:   "Test ArtifactFetcher simple list artifacts",
			source: "gs://test-bucket/logs/example-ci-run/403",
			expectedArtifacts: []string{
				"build-log.txt",
				"started.json",
				"finished.json",
				"junit_01.xml",
				"long-log.txt",
			},
		},
		{
			name:              "Test ArtifactFetcher list artifacts on source with no artifacts",
			source:            "gs://test-bucket/logs/example-ci/404",
			expectedArtifacts: []string{},
		},
	}

	for _, tc := range testCases {
		jobSrc, err := testAf.createJobSource(tc.source)
		if err != nil {
			t.Fatalf("%s failed to create job source for source: %s", tc.name, tc.source)
		}
		actualArtifacts := testAf.artifacts(jobSrc)
		for _, ea := range tc.expectedArtifacts {
			found := false
			for _, aa := range actualArtifacts {
				if ea == aa {
					found = true
					break
				}
			}
			if !found {
				t.Errorf("Case %s failed to retrieve the following artifact: %s\nRetrieved: %s.", tc.name, ea, actualArtifacts)
			}

		}
		if len(tc.expectedArtifacts) != len(actualArtifacts) {
			t.Errorf("Case %s produced more artifacts than expected. Expected: %s\nActual: %s.", tc.name, tc.expectedArtifacts, actualArtifacts)
		}
	}
}

// Tests getting handles to objects associated with the current job in GCS
func TestFetchArtifacts_GCS(t *testing.T) {
	fakeGCSClient := fakeGCSServer.Client()
	testAf := NewGCSArtifactFetcher(fakeGCSClient)
	maxSize := int64(500e6)
	testCases := []struct {
		name         string
		artifactName string
		source       string
		expectedSize int64
		expectErr    bool
	}{
		{
			name:         "Fetch build-log.txt from valid source",
			artifactName: "build-log.txt",
			source:       "gs://test-bucket/logs/example-ci-run/403",
			expectedSize: 25,
		},
		{
			name:         "Fetch build-log.txt from invalid source",
			artifactName: "build-log.txt",
			source:       "gs://test-bucket/logs/example-ci-run/404",
			expectErr:    true,
		},
	}

	for _, tc := range testCases {
		jobSrc, err := testAf.createJobSource(tc.source)
		if err != nil {
			t.Fatalf("%s failed to create job source from source %s", tc.name, tc.source)
		}
		artifact := testAf.artifact(jobSrc, tc.artifactName, maxSize)
		size, err := artifact.Size()
		if err != nil && !tc.expectErr {
			t.Fatalf("%s failed getting size for artifact %s, err: %v", tc.name, artifact.JobPath(), err)
		}
		if err == nil && tc.expectErr {
			t.Errorf("%s expected error, got no error", tc.name)
		}

		if size != tc.expectedSize {
			t.Errorf("%s expected artifact with size %d but got %d", tc.name, tc.expectedSize, size)
		}
	}
}
