package config

import (
	"reflect"
	"testing"
)

func TestPresubmit_GcsPath(t *testing.T) {
	presubmit := Presubmit{
		Job: Job{
			JobName:     "name",
			BuildNumber: 1,
		},
		PullRequest: PullRequest{
			PullNumber: 2,
			PullSha:    "sha",
		},
	}

	if expected, actual := "pr-logs/pull/2/name/1/", presubmit.GcsPath(); expected != actual {
		t.Errorf("expected presubmit job GCS path %s, got %s", expected, actual)
	}
}

func TestPresubmit_Aliases(t *testing.T) {
	presubmit := Presubmit{
		Job: Job{
			JobName:     "name",
			BuildNumber: 1,
		},
		PullRequest: PullRequest{
			PullNumber: 2,
			PullSha:    "sha",
		},
	}

	if expected, actual := []string{"pr-logs/directory/name/1.txt"}, presubmit.Aliases(); !reflect.DeepEqual(actual, expected) {
		t.Errorf("expected presubmit job to have aliases:\n\t%v\n\tgot:\n\t%v", actual, expected)
	}
}

func TestPresubmit_Type(t *testing.T) {
	presubmit := Presubmit{}
	if actual, expected := presubmit.Type(), PresubmitType; !reflect.DeepEqual(actual, expected) {
		t.Errorf("expected presubmit type to be %v, but got %v", expected, actual)
	}
}
