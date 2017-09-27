package config

import (
	"reflect"
	"testing"
)

func TestPostsubmit_GcsPath(t *testing.T) {
	postsubmit := Postsubmit{
		Job: Job{
			JobName:     "name",
			BuildNumber: 1,
		},
		RepoMeta: RepoMeta{
			RepoOwner: "owner",
			RepoName:  "repo",
		},
	}

	if expected, actual := "logs/owner_repo/name/1/", postsubmit.GcsPath(); expected != actual {
		t.Errorf("expected postsubmit job GCS path %s, got %s", expected, actual)
	}
}

func TestPostsubmit_Aliases(t *testing.T) {
	postsubmit := Postsubmit{}
	if actual := postsubmit.Aliases(); len(actual) != 0 {
		t.Errorf("expected postsubmit job to have no aliases, got: %v", actual)
	}
}

func TestPostsubmit_Type(t *testing.T) {
	postsubmit := Postsubmit{}
	if actual, expected := postsubmit.Type(), PostsubmitType; !reflect.DeepEqual(actual, expected) {
		t.Errorf("expected postsubmit type to be %v, but got %v", expected, actual)
	}
}
