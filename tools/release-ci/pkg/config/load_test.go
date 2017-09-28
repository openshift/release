package config

import (
	"errors"
	"fmt"
	"reflect"
	"strings"
	"testing"
)

func TestLoadRawFromReader(t *testing.T) {
	tests := []struct {
		name        string
		raw         string
		expected    anyConfig
		expectedErr error
	}{
		{
			name: "no type",
			raw:  `{"config":{"some":"data"}}`,
			expected: anyConfig{
				Config: []byte(`{"some":"data"}`),
			},
			expectedErr: errors.New("invalid job configuration: no configuration type"),
		},
		{
			name: "no config",
			raw:  `{"type":"batch"}`,
			expected: anyConfig{
				ConfigType: BatchType,
			},
			expectedErr: errors.New("invalid job configuration: no configuration"),
		},
		{
			name: "valid data",
			raw:  `{"type":"batch","config":{"some":"data"}}`,
			expected: anyConfig{
				ConfigType: BatchType,
				Config:     []byte(`{"some":"data"}`),
			},
			expectedErr: nil,
		},
	}

	for _, test := range tests {
		raw, err := loadRawFromReader(strings.NewReader(test.raw))
		if expected, actual := test.expectedErr, err; !reflect.DeepEqual(expected, actual) {
			t.Errorf("%s: expected error:\n\t%v\ngot:\n\t%v", test.name, expected, actual)
		}
		if expected, actual := test.expected, raw; !reflect.DeepEqual(expected, actual) {
			t.Errorf("%s: expected configuration:\n\t%v\ngot:\n\t%v", test.name, expected, actual)
		}
	}
}

func TestLoadPeriodicFromReader(t *testing.T) {
	tests := []struct {
		name        string
		raw         string
		expected    Periodic
		expectedErr error
	}{
		{
			name:        "wrong type",
			raw:         fmt.Sprintf(`{"type":"%s","config":{"some":"data"}}`, BatchType),
			expected:    Periodic{},
			expectedErr: fmt.Errorf("configuration was of type %s, not %s", BatchType, PeriodicType),
		},
		{
			name: "valid data",
			raw:  fmt.Sprintf(`{"type":"%s","config":{"job-name":"name","build-number":1}}`, PeriodicType),
			expected: Periodic{
				Job: Job{
					JobName:     "name",
					BuildNumber: 1,
				},
			},
			expectedErr: nil,
		},
	}

	for _, test := range tests {
		config, err := loadPeriodicFromReader(strings.NewReader(test.raw))
		if expected, actual := test.expectedErr, err; !reflect.DeepEqual(expected, actual) {
			t.Errorf("%s: expected error:\n\t%v\ngot:\n\t%v", test.name, expected, actual)
		}
		if expected, actual := test.expected, config; !reflect.DeepEqual(expected, actual) {
			t.Errorf("%s: expected configuration:\n\t%v\ngot:\n\t%v", test.name, expected, actual)
		}
	}
}

func TestLoadBatchFromReader(t *testing.T) {
	tests := []struct {
		name        string
		raw         string
		expected    Batch
		expectedErr error
	}{
		{
			name:        "wrong type",
			raw:         fmt.Sprintf(`{"type":"%s","config":{"some":"data"}}`, PeriodicType),
			expected:    Batch{},
			expectedErr: fmt.Errorf("configuration was of type %s, not %s", PeriodicType, BatchType),
		},
		{
			name: "valid data",
			raw:  fmt.Sprintf(`{"type":"%s","config":{"job-name":"name","build-number":1,"repo-owner":"owner","repo-name":"repo","base-ref":"ref","base-sha":"sha","pull-refs":"pullrefs"}}`, BatchType),
			expected: Batch{
				Job: Job{
					JobName:     "name",
					BuildNumber: 1,
				},
				Repo: Repo{
					RepoOwner: "owner",
					RepoName:  "repo",
					BaseRef:   "ref",
					BaseSha:   "sha",
					PullRefs:  "pullrefs",
				},
			},
			expectedErr: nil,
		},
	}

	for _, test := range tests {
		config, err := loadBatchFromReader(strings.NewReader(test.raw))
		if expected, actual := test.expectedErr, err; !reflect.DeepEqual(expected, actual) {
			t.Errorf("%s: expected error:\n\t%v\ngot:\n\t%v", test.name, expected, actual)
		}
		if expected, actual := test.expected, config; !reflect.DeepEqual(expected, actual) {
			t.Errorf("%s: expected configuration:\n\t%v\ngot:\n\t%v", test.name, expected, actual)
		}
	}
}

func TestLoadPostsubmitFromReader(t *testing.T) {
	tests := []struct {
		name        string
		raw         string
		expected    Postsubmit
		expectedErr error
	}{
		{
			name:        "wrong type",
			raw:         fmt.Sprintf(`{"type":"%s","config":{"some":"data"}}`, BatchType),
			expected:    Postsubmit{},
			expectedErr: fmt.Errorf("configuration was of type %s, not %s", BatchType, PostsubmitType),
		},
		{
			name: "valid data",
			raw:  fmt.Sprintf(`{"type":"%s","config":{"job-name":"name","build-number":1,"repo-owner":"owner","repo-name":"repo","base-ref":"ref","base-sha":"sha","pull-refs":"pullrefs"}}`, PostsubmitType),
			expected: Postsubmit{
				Job: Job{
					JobName:     "name",
					BuildNumber: 1,
				},
				Repo: Repo{
					RepoOwner: "owner",
					RepoName:  "repo",
					BaseRef:   "ref",
					BaseSha:   "sha",
					PullRefs:  "pullrefs",
				},
			},
			expectedErr: nil,
		},
	}

	for _, test := range tests {
		config, err := loadPostsubmitFromReader(strings.NewReader(test.raw))
		if expected, actual := test.expectedErr, err; !reflect.DeepEqual(expected, actual) {
			t.Errorf("%s: expected error:\n\t%v\ngot:\n\t%v", test.name, expected, actual)
		}
		if expected, actual := test.expected, config; !reflect.DeepEqual(expected, actual) {
			t.Errorf("%s: expected configuration:\n\t%v\ngot:\n\t%v", test.name, expected, actual)
		}
	}
}

func TestLoadPresubmitFromReader(t *testing.T) {
	tests := []struct {
		name        string
		raw         string
		expected    Presubmit
		expectedErr error
	}{
		{
			name:        "wrong type",
			raw:         fmt.Sprintf(`{"type":"%s","config":{"some":"data"}}`, BatchType),
			expected:    Presubmit{},
			expectedErr: fmt.Errorf("configuration was of type %s, not %s", BatchType, PresubmitType),
		},
		{
			name: "valid data",
			raw:  fmt.Sprintf(`{"type":"%s","config":{"job-name":"name","build-number":1,"repo-owner":"owner","repo-name":"repo","base-ref":"ref","base-sha":"sha","pull-refs":"pullrefs","pull-number":1,"pull-sha":"sha"}}`, PresubmitType),
			expected: Presubmit{
				Job: Job{
					JobName:     "name",
					BuildNumber: 1,
				},
				Repo: Repo{
					RepoOwner: "owner",
					RepoName:  "repo",
					BaseRef:   "ref",
					BaseSha:   "sha",
					PullRefs:  "pullrefs",
				},
				PullRequest: PullRequest{
					PullNumber: 1,
					PullSha:    "sha",
				},
			},
			expectedErr: nil,
		},
	}

	for _, test := range tests {
		config, err := loadPresubmitFromReader(strings.NewReader(test.raw))
		if expected, actual := test.expectedErr, err; !reflect.DeepEqual(expected, actual) {
			t.Errorf("%s: expected error:\n\t%v\ngot:\n\t%v", test.name, expected, actual)
		}
		if expected, actual := test.expected, config; !reflect.DeepEqual(expected, actual) {
			t.Errorf("%s: expected configuration:\n\t%v\ngot:\n\t%v", test.name, expected, actual)
		}
	}
}
